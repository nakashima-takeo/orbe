import AppKit
import XCTest

@testable import Orbe

/// 器の再レイアウトが相互作用（取っ手を引く操作・面の動き）を捨てないことを実窓で固定する。
///
/// 壊れると何が起きるか。投影の変化が chrome 更新を起こし、SwiftUI のレイアウトが器の `layout()` を
/// 呼ぶ経路は常に生きている。そこで確定配置へ戻すと、取っ手を引いた瞬間に掴む前の配置へ巻き戻り、
/// ⌘E の動きは 1 フレームも走らずに終点へ飛ぶ。
extension WindowControllerFacesTests {
  /// ドラッグ中に器が再レイアウトされても（投影の変化が chrome 更新を起こし、SwiftUI のレイアウトが
  /// 器の `layout()` を呼ぶ経路）、面は掴む前の配置へ戻らない。
  func testHandleDragSurvivesRelayoutDuringTheDrag() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    let handle = tab.view.handle
    let grab = handle.centerInWindow
    let offset = grab.x - handle.frame.minX
    let y = grab.y

    handle.mouseDown(with: .mouse(.leftMouseDown, at: grab, in: wc.window))
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: NSPoint(x: 500, y: y), in: wc.window))
    let ratio = try XCTUnwrap(FaceGeometry.ratio(hx: 500 - offset, width: facesWidth(wc)))
    tab.view.needsLayout = true
    layout(wc)
    XCTAssertEqual(tab.view.resolved.shape.hx, 500 - offset, "再レイアウト後もドラッグ中の位置のまま")
    XCTAssertEqual(handle.frame.minX, 500 - offset, "取っ手も動かない")

    handle.mouseUp(with: .mouse(.leftMouseUp, at: NSPoint(x: 500, y: y), in: wc.window))
    XCTAssertEqual(tab.faces.editorRatio, ratio, accuracy: 0.0001, "離した位置で確定")
  }

  /// ⌘E の動きは再レイアウトで終点へ飛ばず、フレームごとに境が段階的に動き、止まったところで確定する。
  func testToggleEditorFaceSlidesTheBoundaryOverTime() throws {
    try XCTSkipIf(
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion では遷移しない")
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    let editorFace = try XCTUnwrap(tab.view.editor.superview)
    let full = facesWidth(wc)

    wc.handleWindowCommand(.toggleEditorFace)
    tab.view.tick(dt: 0.02)
    tab.view.needsLayout = true
    layout(wc)
    XCTAssertGreaterThan(editorFace.frame.maxX, 0, "動きが始まっている")
    XCTAssertLessThan(editorFace.frame.maxX, full, "再レイアウトしても終点へ飛ばない")

    tab.view.tick(dt: 0.05)
    let mid = editorFace.frame.maxX
    XCTAssertGreaterThan(mid, 0)
    XCTAssertLessThan(mid, full, "途中は起点と終点の間")

    var frames = 0
    while tab.view.isAnimating, frames < 600 {
      tab.view.tick(dt: 1.0 / 120)
      frames += 1
    }
    XCTAssertEqual(editorFace.frame.maxX, full, "止まったところで確定配置へ着地")
    XCTAssertEqual(tab.view.resolved.editorWidth, full)
  }
}
