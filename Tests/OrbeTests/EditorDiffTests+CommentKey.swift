import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// PR の画面のキー c——焦点のある差分の面の本文の、キャレットの行か選択の行の範囲に、新しいコメントの欄を開く。コメントの欄で
/// 打っている間は字として入る。
///
/// 壊れると何が起きるか: マウスなしではコメントを始められない。返信を打っている最中に c を打つと欄が開いて字が入らない。選択の
/// 最後の行の次の行頭まで選んだときに、1 行多い範囲の欄が開く。
extension EditorDiffTests {
  /// キャレットの行に 1 行の欄が、選択があればその行の範囲の欄が開く（選択が行頭で終わっていれば、その行は含めない）。
  func testCOpensADraftOnTheCaretLineOrTheSelectedLines() throws {
    let (diff, tab) = try commentedTab(Remote())
    let pane = tab.group.view.editor
    let surface = try engine(diff.newSurface)
    let window = try XCTUnwrap(pane.window)
    window.makeFirstResponder(surface.responder)
    let layer = try XCTUnwrap(diff.comments)
    let text = try XCTUnwrap(diff.newRevision?.text ?? diff.document?.text)

    surface.selectedRange = NSRange(location: text.lineStart(1) + 1, length: 0)
    XCTAssertTrue(pane.handleCommentKey(.key("c", [])))
    XCTAssertNotNil(layer.draft(at: .at(.new, 1)), "キャレットの行")

    window.makeFirstResponder(surface.responder)
    surface.selectedRange = NSRange(
      location: text.lineStart(0), length: text.lineStart(3) - text.lineStart(0))
    XCTAssertTrue(pane.handleCommentKey(.key("c", [])))
    XCTAssertNotNil(
      layer.draft(
        at: DiffLineRange(
          start: DiffLine(version: .new, line: 0), end: DiffLine(version: .new, line: 2))),
      "行頭で終わる選択は、その行を含めない")
    XCTAssertFalse(pane.handleCommentKey(.key("c")), "⌘c は扱わない")
  }

  /// 欄で打っている間は、c を扱わない（字として欄に入る）。
  func testCIsTypedIntoACommentField() throws {
    let (diff, tab) = try commentedTab(Remote())
    let pane = tab.group.view.editor
    let surface = try engine(diff.newSurface)
    let window = try XCTUnwrap(pane.window)
    window.makeFirstResponder(surface.responder)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didMarkFrom: .document(1), to: .document(1))
    XCTAssertNotNil(layer.draft(at: .at(.new, 1)), "前提: 欄にフォーカス")
    XCTAssertFalse(pane.handleCommentKey(.key("c", [])))
  }
}
