import OrbeTestSupport
import XCTest

@testable import Orbe

/// 面の器の取っ手（fixture は `EditorShellFixtures`。配置・引く・ホバーは本物の口が生む）。端末だけの左縁の引き手
/// （普段・ホバー）→ エディター全面の右縁の窓と ❯_ の引き手（普段・ホバー。スクロールバーに重なる）→ 引き手を縁から 28
/// 引いた途中の形（両面の間の列が継ぎ目の地で埋まる）→ 分割中の継ぎ目（普段・ホバー。エディターの焦点の帯）を dark で、
/// 続けて同じ並びを light で撮る。動きとホバーは器のフレームを止まるまで刻んでから撮り、面を付けた窓の中でそのまま描く。
extension DesignFlowSnapshotTests {
  func testFacesHandle() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    let tab = scene.tab
    let view = tab.group.view
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
    tab.group.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    view.layoutSubtreeIfNeeded()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    let handle = view.handle
    let pointer = { (inside: Bool) in
      let event = NSEvent.mouse(.mouseMoved, at: handle.centerInWindow, in: window)
      if inside { handle.mouseEntered(with: event) } else { handle.mouseExited(with: event) }
    }
    let morph = {
      pointer(false)
      tab.group.setFaces(.terminalOnly, animated: false)
      let x0 = handle.frame.midX
      handle.onGrab?(x0)
      handle.onDrag?(x0 + 28, 0)
    }
    let split = FaceLayout(editorRatio: 0.5, focus: .editor)
    var steps: [(label: String, action: () -> Void)] = []
    for (appearance, suffix) in [(NSAppearance.Name.darkAqua, ""), (.aqua, "_light")] {
      let layouts: [(label: String, faces: FaceLayout)] = [
        ("terminal", .terminalOnly), ("editor", FaceLayout(editorRatio: 1, focus: .editor)),
      ]
      for layout in layouts {
        steps.append(
          (
            "\(layout.label)_rest\(suffix)",
            {
              window.appearance = NSAppearance(named: appearance)
              pointer(false)
              tab.group.setFaces(layout.faces, animated: false)
            }
          ))
        steps.append(("\(layout.label)_hover\(suffix)", { pointer(true) }))
      }
      steps.append(("morph\(suffix)", morph))
      steps.append(("seam_rest\(suffix)", { tab.group.setFaces(split, animated: false) }))
      steps.append(("seam_hover\(suffix)", { pointer(true) }))
    }
    for (idx, step) in steps.enumerated() {
      step.action()
      view.layoutSubtreeIfNeeded()
      for _ in 0..<120 { view.tick(dt: 1.0 / 60) }
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      try writeFacesShot(ground, name: String(format: "faces_handle_%02d_%@", idx, step.label))
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
