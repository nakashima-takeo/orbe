import AppKit
import Metal
import OrbeEditorCore
import OrbeTestSupport
import XCTest
import os

@testable import OrbeEditorEngine

/// 絵の差し込みは本文と同じコマに描かれる——窓を出さず画面外に、テストが 1/120 秒ごとに打つ刻みで描き、合成のはじき
/// （6000pt/s）と端の弾みを流しながら、描画スレッドが出したコマを 1 枚ずつ読む。出来事とコマの時刻はテストが決め、刻みの
/// 時刻までの出来事を面へ流してから、その刻みのコマを描かせる。読んだコマから、絵の差し込みの上端・下端と、上下の
/// 印の行（全角の塗りの字）の字の画素の距離を引く。絵の差し込みと本文が同じコマに組まれていれば、距離はどのコマでも
/// 同じ。壊れると（絵の差し込みを別の刻み・別の位置で描くと）、速いスクロールの間に絵の差し込みが本文の空きから離れたり
/// 行に重なったりする。
@MainActor
final class SurfaceZoneFramesTests: EngineTestCase {
  func testZonesStayInTheGapThroughAFlickAndABounce() throws {
    let lines = (0..<400).map { line in
      line % 20 == 19 || (line % 20 == 0 && line > 0)
        ? String(repeating: "\u{2588}", count: 8) : "let value\(line) = \(line)"
    }
    let opened = try open(
      lines.joined(separator: "\n") + "\n", size: CGSize(width: 500, height: 400))
    let surface = opened.surface
    surface.setPresentation(SurfacePresentation(showsMinimap: false))
    let magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
    surface.setRows(
      SurfaceRows(
        insertions: stride(from: 20, to: 400, by: 20).map {
          RowInsertion(line: $0, content: .zone(BoxZone(height: 41, color: magenta)))
        }))
    surface.viewStateDidChange(size: CGSize(width: 500, height: 400), scale: 2, visible: true)
    let left = surface.surfaceLayout.text.minX
    let probe = FrameProbe(
      zoneX: Int((left + 100) * 2), markerX: Int((left + 10) * 2),
      top: Int((surface.config.topInset + 8) * 2))
    let id = surface.id
    let target = CapturingTarget(device: try XCTUnwrap(RenderThread.device), probe: probe)
    let clock = ManualClock()
    RenderThread.shared.perform { $0.bind(id, target: target, clock: clock) }
    waitForPipelines()
    surface.scroll(toFirstLine: 10)
    surface.flush()
    var now = CACurrentMediaTime()
    flick(surface, peak: 6000, target: target, now: &now)
    flick(surface, peak: -6000, target: target, now: &now)
    flick(surface, peak: -6000, target: target, now: &now)
    let gaps = probe.gaps
    print(
      "[zone-frames] frames \(probe.frames), zones \(gaps.above.count)",
      "above \(gaps.above.min() ?? -1)...\(gaps.above.max() ?? -1)",
      "below \(gaps.below.min() ?? -1)...\(gaps.below.max() ?? -1)")
    XCTAssertGreaterThan(probe.frames, 60, "前提: スクロールの間のコマを読んだ")
    XCTAssertGreaterThan(gaps.above.count, 60, "前提: 絵の差し込みと上下の印の行を引けた")
    XCTAssertEqual(gaps.above.min(), gaps.above.max(), "絵の差し込みの上端と上の行の距離は、どのコマでも同じ")
    XCTAssertEqual(gaps.below.min(), gaps.below.max(), "絵の差し込みの下端と下の行の距離は、どのコマでも同じ")
    XCTAssertGreaterThan(gaps.above.min() ?? 0, 0, "絵の差し込みは上の行の字に重ならない")
    XCTAssertGreaterThan(gaps.below.min() ?? 0, 0, "絵の差し込みは下の行の字に重ならない")
  }

  /// はじく: 80ms で速さ `peak`（pt/秒。正は下へ送る）まで上げて離し、OS の momentum の出来事（0.95 倍ずつ落ちる列）が
  /// 続く。時刻 `now` から始め、出来事が尽きた後も 0.3 秒ぶんの刻みを打ち、`now` を最後の刻みの時刻へ進める。
  private func flick(
    _ surface: MetalTextSurface, peak: Double, target: CapturingTarget, now: inout Double
  ) {
    typealias Planned = FramePerfTests.Planned
    let step = 0.0057
    var inputs = [Planned(at: 0, phase: .began)]
    let ramp = Int(0.08 / step)
    for k in 1...ramp {
      inputs.append(
        Planned(
          at: Double(k) * step, phase: .changed, dy: -peak * Double(k) / Double(ramp) * step))
    }
    var t = Double(ramp + 1) * step
    inputs.append(Planned(at: t, phase: .ended))
    var d = -peak * step
    inputs.append(Planned(at: t, momentum: .began, dy: d))
    while abs(d) > 0.5 {
      t += step
      d *= 0.95
      inputs.append(Planned(at: t, momentum: .changed, dy: d))
    }
    inputs.append(Planned(at: t + step, momentum: .ended))
    let start = now
    let end = start + inputs[inputs.count - 1].at + 0.3
    var next = 0
    while now < end {
      now += HeadlessDriver.period
      while next < inputs.count, start + inputs[next].at <= now {
        let input = inputs[next]
        surface.scroll(
          ScrollInput(
            timestamp: start + input.at, delta: SIMD2(0, input.dy), precise: true,
            phase: input.phase, momentum: input.momentum))
        next += 1
      }
      tick(surface, at: now, target: target)
    }
  }

  /// 時刻 `now` の刻みを打つ（コマは次の刻みの時刻に画面に出る予定）。描いたら、そのコマが読まれるまで待つ。
  private func tick(_ surface: MetalTextSurface, at now: Double, target: CapturingTarget) {
    surface.flush()
    let id = surface.id
    let shown = now + HeadlessDriver.period
    RenderThread.shared.performAndWait { $0.tick(id, target: shown) }
    pumpMain(until: { target.delivered == target.acquired }, "描いたコマを読む")
  }
}

/// 描いたコマの画素から、絵の差し込み（`zoneX` の列で、絵の差し込みの塗りの画素が続く行）ごとに、上端と上の印の行の字の
/// 下端・下端と下の印の行の字の上端の距離（画素）を引く。印の行は `markerX` の列で明るい画素の行。
private final class FrameProbe: Sendable {
  struct Gaps {
    var above: [Int] = []
    var below: [Int] = []
  }

  let zoneX: Int
  let markerX: Int
  let top: Int
  private let state = OSAllocatedUnfairLock(initialState: (frames: 0, gaps: Gaps()))

  init(zoneX: Int, markerX: Int, top: Int) {
    self.zoneX = zoneX
    self.markerX = markerX
    self.top = top
  }

  var frames: Int { state.withLock { $0.frames } }
  var gaps: Gaps { state.withLock { $0.gaps } }

  func read(_ bytes: [UInt8], width: Int, height: Int) {
    let pixel = { (x: Int, y: Int) -> (Int, Int) in
      let i = (y * width + x) * 4
      return (Int(bytes[i + 2]), Int(bytes[i + 1]))
    }
    let zone = { (y: Int) in pixel(self.zoneX, y) == (255, 0) }
    let bright = { (y: Int) in
      let (r, g) = pixel(self.markerX, y)
      return r > 120 && g > 120
    }
    var found = Gaps()
    var y = top
    while y < height {
      guard zone(y) else {
        y += 1
        continue
      }
      let first = y
      while y + 1 < height, zone(y + 1) { y += 1 }
      let last = y
      y += 1
      var a = first - 1
      while a > top, !bright(a) { a -= 1 }
      var c = last + 1
      while c < height - 1, !bright(c) { c += 1 }
      guard first > top + 1, last < height - 2, a > top, c < height - 1 else { continue }
      found.above.append(first - a)
      found.below.append(c - last)
    }
    let read = found
    state.withLock {
      $0.frames += 1
      $0.gaps.above += read.above
      $0.gaps.below += read.below
    }
  }
}

/// 画面外のテクスチャ 3 枚へ出し、GPU が描き終えたコマを読んで `FrameProbe` に渡し、すぐ「画面に出た」と知らせる。描く先を
/// 取った回数（描いたコマの数）と、読み終えたコマの数を数える。
private final class CapturingTarget: FrameTarget, @unchecked Sendable {
  private let textures: [MTLTexture]
  private let probe: FrameProbe
  private var next = 0
  private let count = OSAllocatedUnfairLock(initialState: 0)

  /// 描く先を取った回数（描いたコマの数）。
  var acquired: Int { count.withLock { $0 } }
  /// 読み終えたコマの数。読み手が main のキューで足すので、これを条件に待つ main は、見直しの間隔を待たずに読み終えた
  /// 知らせで起きる。
  @MainActor private(set) var delivered = 0

  init(device: MTLDevice, probe: FrameProbe) {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: 1000, height: 800, mipmapped: false)
    descriptor.usage = .renderTarget
    descriptor.storageMode = .shared
    textures = (0..<3).map { _ in device.makeTexture(descriptor: descriptor)! }
    self.probe = probe
  }

  /// テストは、コマが読まれたら次の刻みを打つ。「画面に出た」が描画スレッドに届くのは読まれた後なので、届く前に打った
  /// 刻みが上限に当たって飛ばされないよう、画面に出ていないコマの上限を大きくする。
  var limit: Int { 1_000 }

  func acquire() -> AcquiredFrame? {
    let texture = textures[next % textures.count]
    next += 1
    count.withLock { $0 += 1 }
    let probe = probe
    return AcquiredFrame(texture: texture) { commands, shown in
      commands.addCompletedHandler { _ in
        let width = texture.width
        let height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(
          &bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
          mipmapLevel: 0)
        probe.read(bytes, width: width, height: height)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.delivered += 1 } }
        shown(CACurrentMediaTime())
      }
    }
  }
}
