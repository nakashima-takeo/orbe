import AppKit
import XCTest

@testable import Orbe

/// 器の再レイアウトが相互作用（背のドラッグ・面の遷移）を捨てないことを実窓で固定する。
///
/// 壊れると何が起きるか。投影の変化が chrome 更新を起こし、SwiftUI のレイアウトが器の `layout()` を
/// 呼ぶ経路は常に生きている。そこで確定配置へ戻すと、背を引いた瞬間に掴む前の配置へ巻き戻り、
/// ⌘E の遷移は 1 フレームも走らずに終点へ飛ぶ。
extension WindowControllerFacesTests {
  /// ドラッグ中に器が再レイアウトされても（投影の変化が chrome 更新を起こし、SwiftUI のレイアウトが
  /// 器の `layout()` を呼ぶ経路）、面は掴む前の配置へ戻らない。
  func testSpineDragSurvivesRelayoutDuringTheDrag() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    let spine = tab.view.spine
    let grab = spine.centerInWindow
    let offset = grab.x - spine.frame.minX
    let y = grab.y

    spine.mouseDown(with: .mouse(.leftMouseDown, at: grab, in: wc.window))
    spine.mouseDragged(with: .mouse(.leftMouseDragged, at: NSPoint(x: 500, y: y), in: wc.window))
    tab.view.needsLayout = true
    layout(wc)
    XCTAssertEqual(tab.view.resolved.editorWidth, 500 - offset, "再レイアウト後もドラッグ中の幅のまま")
    XCTAssertEqual(spine.frame.minX, 500 - offset, "背も動かない")

    spine.mouseUp(with: .mouse(.leftMouseUp, at: NSPoint(x: 500, y: y), in: wc.window))
    XCTAssertEqual(
      tab.faces.editorRatio * contentWidth(wc), 500 - offset, accuracy: 0.5, "離した幅で確定")
  }

  /// ⌘E の遷移は再レイアウトで終点へ飛ばず、時間に沿って背が段階的に動き、終端で確定する。
  func testToggleEditorFaceSlidesTheSpineOverTime() throws {
    try XCTSkipIf(
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion では遷移しない")
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    let spine = tab.view.spine
    let full = contentWidth(wc)

    let start = CACurrentMediaTime()
    wc.handleWindowCommand(.toggleEditorFace)
    pump(0.02)
    tab.view.needsLayout = true
    layout(wc)
    XCTAssertGreaterThan(spine.frame.minX, 0, "遷移が始まっている")
    XCTAssertLessThan(spine.frame.minX, full, "再レイアウトしても終点へ飛ばない")

    tab.view.slideFrame(now: start + Theme.Motion.faceSlide / 2)
    let mid = spine.frame.minX
    XCTAssertGreaterThan(mid, 0)
    XCTAssertLessThan(mid, full, "途中は起点と終点の間")

    tab.view.slideFrame(now: start + Theme.Motion.faceSlide + 0.05)
    XCTAssertEqual(spine.frame.minX, full, "終端で確定配置へ着地")
    XCTAssertEqual(tab.view.resolved.editorWidth, full)
  }
}
