import AppKit
import Metal
import OrbeEditorCore
import XCTest
import os

@testable import OrbeEditorEngine

/// 区画は本文と同じコマに描かれる——窓を出さず画面外に実際の刻み（120Hz）で描き、合成のはじき（6000pt/s）と端の弾みを
/// 流しながら、描画スレッドが出したコマを 1 枚ずつ読み、区画の上端・下端と、上下の印の行（全角の塗りの字）の字の画素の
/// 距離を引く。区画と本文が同じコマに組まれていれば、距離はどのコマでも同じ。壊れると（区画を別の刻み・別の位置で描く
/// と）、速いスクロールの間に区画が本文の空きから離れたり行に重なったりする。
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
    let driver = HeadlessDriver()
    driver.start()
    defer { driver.stop() }
    let id = surface.id
    let target = CapturingTarget(device: try XCTUnwrap(RenderThread.device), probe: probe)
    let clock = VirtualClock(id: id, driver: driver)
    driver.setPaused(id, false)
    RenderThread.shared.perform { $0.bind(id, target: target, clock: clock) }
    surface.scroll(toFirstLine: 10)
    surface.flush()
    flick(surface, peak: 6000)
    flick(surface, peak: -6000)
    flick(surface, peak: -6000)
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    let gaps = probe.gaps
    print(
      "[zone-frames] frames \(probe.frames), zones \(gaps.above.count)",
      "above \(gaps.above.min() ?? -1)...\(gaps.above.max() ?? -1)",
      "below \(gaps.below.min() ?? -1)...\(gaps.below.max() ?? -1)")
    XCTAssertGreaterThan(probe.frames, 60, "前提: スクロールの間のコマを読んだ")
    XCTAssertGreaterThan(gaps.above.count, 60, "前提: 区画と上下の印の行を引けた")
    XCTAssertEqual(gaps.above.min(), gaps.above.max(), "区画の上端と上の行の距離は、どのコマでも同じ")
    XCTAssertEqual(gaps.below.min(), gaps.below.max(), "区画の下端と下の行の距離は、どのコマでも同じ")
    XCTAssertGreaterThan(gaps.above.min() ?? 0, 0, "区画は上の行の字に重ならない")
    XCTAssertGreaterThan(gaps.below.min() ?? 0, 0, "区画は下の行の字に重ならない")
  }

  /// はじく: 80ms で速さ `peak`（pt/秒。正は下へ送る）まで上げて離し、OS の momentum の出来事（0.95 倍ずつ落ちる列）が
  /// 続く。出来事は実時間で面の入口へ流す。
  private func flick(_ surface: MetalTextSurface, peak: Double) {
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
    let start = CACurrentMediaTime()
    for input in inputs {
      while CACurrentMediaTime() < start + input.at {
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
      }
      surface.scroll(
        ScrollInput(
          timestamp: CACurrentMediaTime(), delta: SIMD2(0, input.dy), precise: true,
          phase: input.phase, momentum: input.momentum))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  }
}

/// 描いたコマの画素から、区画（`zoneX` の列で区画の塗りの画素の続く行）ごとに、上端と上の印の行の字の下端・下端と下の
/// 印の行の字の上端の距離（画素）を引く。印の行は `markerX` の列で明るい画素の行。
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
    state.withLock {
      $0.frames += 1
      $0.gaps.above += found.above
      $0.gaps.below += found.below
    }
  }
}

/// 画面外のテクスチャ 3 枚へ出し、GPU が描き終えたコマを読んで `FrameProbe` に渡し、すぐ「画面に出た」と知らせる。
private final class CapturingTarget: FrameTarget, @unchecked Sendable {
  private let textures: [MTLTexture]
  private let probe: FrameProbe
  private var next = 0

  init(device: MTLDevice, probe: FrameProbe) {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: 1000, height: 800, mipmapped: false)
    descriptor.usage = .renderTarget
    descriptor.storageMode = .shared
    textures = (0..<3).map { _ in device.makeTexture(descriptor: descriptor)! }
    self.probe = probe
  }

  var limit: Int { 1 }

  func acquire() -> AcquiredFrame? {
    let texture = textures[next % textures.count]
    next += 1
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
        shown(CACurrentMediaTime())
      }
    }
  }
}
