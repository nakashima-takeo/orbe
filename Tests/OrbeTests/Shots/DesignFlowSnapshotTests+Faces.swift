import OrbeTestSupport
import XCTest

@testable import Orbe

/// 連の器の見せ方（fixture は `EditorShellFixtures`。見せ方は器の口が写す）: 閉じた器（端末面が器の左端から右端まで）→
/// 開いた器（エディター面が器いっぱいに重なる）→ 透かし（エディター面が写らず、閉じた器と同じ姿）を dark で、続けて同じ並びを
/// light で撮る。面を付けた窓の中でそのまま描く。
extension DesignFlowSnapshotTests {
  func testFacesOverlay() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    let view = scene.group.view
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 640), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let ground = WindowGround(frame: NSRect(x: 0, y: 0, width: 1100, height: 640))
    view.frame = ground.bounds
    view.autoresizingMask = [.width, .height]
    ground.addSubview(view)
    window.contentView = ground
    defer { window.contentView = nil }
    view.show(.editor, animated: false)
    view.layoutSubtreeIfNeeded()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    var idx = 0
    for (appearance, suffix) in [(NSAppearance.Name.darkAqua, ""), (.aqua, "_light")] {
      window.appearance = NSAppearance(named: appearance)
      for (label, mode) in [
        ("closed", GroupFacesView.Mode.terminal), ("open", .editor), ("peek", .peek),
      ] {
        view.show(mode, animated: false)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try writeFacesShot(
          ground, name: String(format: "faces_overlay_%02d_%@", idx, label + suffix))
        idx += 1
      }
    }
  }

  private func writeFacesShot(_ view: NSView, name: String) throws {
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    let url = previewDir("flows").appendingPathComponent("\(name).png")
    try data.write(to: url)
    print("[flow] wrote \(url.path)")
  }
}

/// 不透明時の窓の地（`bg.base`）。器はこの上に重なる。
private final class WindowGround: NSView {
  override func draw(_ dirtyRect: NSRect) {
    Theme.Color.bgBase.setFill()
    bounds.fill()
  }
}
