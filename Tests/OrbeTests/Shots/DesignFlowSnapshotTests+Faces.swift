import OrbeTestSupport
import XCTest

@testable import Orbe

/// 面の器の取っ手（fixture は `EditorShellFixtures`。配置とホバーは本物の口が生む）。端末だけの左縁の引き手（普段・
/// ホバー）→ エディター全面の右縁の引き手（普段・ホバー。スクロールバーに重なる）→ 分割中の継ぎ目（線とグリップ）を
/// dark で、続けて同じ並びを light で撮る。ホバーは窓の中の器に合成のポインタで起こすので、面を付けた窓の中でそのまま描く。
extension DesignFlowSnapshotTests {
  func testFacesHandle() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    let tab = scene.tab
    let view = tab.view
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 640), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.contentView = nil }
    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    view.layoutSubtreeIfNeeded()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    let handle = view.handle
    let pointer = { (inside: Bool) in
      let event = NSEvent.mouse(.mouseMoved, at: handle.centerInWindow, in: window)
      if inside { handle.mouseEntered(with: event) } else { handle.mouseExited(with: event) }
    }
    let layouts: [(label: String, faces: FaceLayout)] = [
      ("terminal", .terminalOnly),
      ("editor", FaceLayout(editorRatio: 1, focus: .editor)),
    ]
    var steps: [(label: String, action: () -> Void)] = []
    for (appearance, suffix) in [(NSAppearance.Name.darkAqua, ""), (.aqua, "_light")] {
      for layout in layouts {
        steps.append(
          (
            "\(layout.label)_rest\(suffix)",
            {
              window.appearance = NSAppearance(named: appearance)
              pointer(false)
              tab.setFaces(layout.faces, animated: false)
            }
          ))
        steps.append(("\(layout.label)_hover\(suffix)", { pointer(true) }))
      }
      steps.append(
        (
          "split\(suffix)",
          {
            pointer(false)
            tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .editor), animated: false)
          }
        ))
    }
    for (idx, step) in steps.enumerated() {
      step.action()
      view.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: rep)
      let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      let url = previewDir("flows").appendingPathComponent(
        String(format: "faces_handle_%02d_%@.png", idx, step.label))
      try data.write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }
}
