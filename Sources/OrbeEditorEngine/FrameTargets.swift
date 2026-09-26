import AppKit
import Metal
import QuartzCore

/// 描く先 1 枚。`present` は命令の列に出す手続きを積み、画面に出たら（捨てられたら nil で）`done` を呼ぶ。
struct AcquiredFrame {
  let texture: MTLTexture
  let present: (MTLCommandBuffer, @escaping @Sendable (Double?) -> Void) -> Void
}

/// コマを出す先。画面（`CAMetalLayer` の drawable）か、計測の画面外のテクスチャ。描画スレッドだけが触る。
protocol FrameTarget: AnyObject {
  /// 画面に出ていない（present も破棄もされていない）コマの上限。上限なら待たずにそのコマを飛ばす。
  var limit: Int { get }
  func acquire() -> AcquiredFrame?
}

/// 表示の刻み。描画スレッドだけが触る。
protocol FrameClock: AnyObject {
  var isPaused: Bool { get set }
  /// 刻みの長さ（秒）。
  var period: Double { get }
  /// `now` より後で次に画面に出る刻みの時刻。
  func nextTarget(after now: Double) -> Double
  func invalidate()
}

/// 画面の drawable へ出す。drawable は 2 枚で、画面に出ていないコマは 1 つまで——画面に出ている 1 枚の他に空きが
/// あるときだけ取るので、`nextDrawable` は実際には待たない。
final class LayerTarget: FrameTarget {
  private let layer: CAMetalLayer

  init(layer: CAMetalLayer) {
    self.layer = layer
  }

  var limit: Int { layer.maximumDrawableCount - 1 }

  func acquire() -> AcquiredFrame? {
    guard let drawable = layer.nextDrawable() else { return nil }
    return AcquiredFrame(texture: drawable.texture) { commands, done in
      drawable.addPresentedHandler { shown in
        done(shown.presentedTime > 0 ? shown.presentedTime : nil)
      }
      commands.present(drawable)
    }
  }
}

/// view の display link を描画スレッドの run loop に載せた刻み（view が載る画面の刻みに従う）。
final class DisplayLinkClock: FrameClock {
  private let link: CADisplayLink

  init(link: CADisplayLink) {
    self.link = link
    link.add(to: .current, forMode: .default)
  }

  var isPaused: Bool {
    get { link.isPaused }
    set { link.isPaused = newValue }
  }

  var period: Double { link.duration > 0 ? link.duration : 1.0 / 120 }

  func nextTarget(after now: Double) -> Double {
    var target = link.targetTimestamp
    while target <= now { target += period }
    return target
  }

  func invalidate() { link.invalidate() }
}

/// display link の呼び出し口（main で作り、描画スレッドの run loop で呼ばれる）。
final class DisplayLinkTarget: NSObject {
  private let id: Int

  init(id: Int) {
    self.id = id
  }

  @objc func step(_ link: CADisplayLink) {
    let target = link.targetTimestamp
    RenderThread.shared.onThread { $0.tick(id, target: target) }
  }
}
