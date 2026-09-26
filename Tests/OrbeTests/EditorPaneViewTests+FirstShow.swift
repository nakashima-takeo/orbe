import AppKit
import XCTest

@testable import Orbe
@testable import OrbeEditorCore

/// 文書を初めて画面に出すときだけ最初の色を待つ——エディター面が見えていない（畳まれた・窓に無い）pane に結んだ文書は
/// 待たず、面が見えたときに待つ。壊れると、端末だけの配置のタブを復元するたびに main が最大 50ms 止まる。
extension EditorPaneViewTests {
  func testADocumentShownInAHiddenEditorFaceWaitsOnlyWhenTheFaceAppears() throws {
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 600)
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    tab.setFaces(.terminalOnly, animated: false)
    tab.view.layoutSubtreeIfNeeded()
    let document = try tab.editor.open(try caseFile("h.swift", "let a = 1\n"))
    XCTAssertTrue(tab.view.editor.isHiddenOrHasHiddenAncestor, "前提: エディター面は畳まれている")
    XCTAssertFalse(document.hasBeenShown, "見えていない面では待たない")

    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(document.hasBeenShown, "面が見えたときに待つ")
  }

  func testADocumentShownInAPaneOutsideAWindowDoesNotWait() throws {
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let document = try tab.editor.open(try caseFile("w.swift", "let a = 1\n"))
    XCTAssertNil(tab.view.editor.window, "前提: 窓に無い")
    XCTAssertFalse(document.hasBeenShown, "窓に無い面では待たない")
  }
}
