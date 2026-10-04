import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 複数カーソルの見せ方——カーソルを足したときは足したカーソルを、打鍵では主のキャレットを見せる。壊れると、⌘D で足した
/// 画面外の一致が見えない・⌥⌘↑↓ で伸ばした端が見えない・⌥クリックで画面外の主へ飛ぶ・打鍵した主の字が画面外のまま。
extension SurfaceMultiCursorTests {
  /// 行 `rows` に `word` を置き、他の行は「x」の本文（見えている高さは約 33 行）。
  private func opened(_ word: String, at rows: Set<Int>) throws -> Opened {
    let text = (0..<300).map { rows.contains($0) ? word : "x" }.joined(separator: "\n") + "\n"
    let opened = try open(text, name: "a.txt", size: CGSize(width: 800, height: 604))
    _ = host(opened, size: CGSize(width: 800, height: 604))
    return opened
  }

  private func place(_ opened: Opened, _ cursors: [Cursor]) {
    opened.surface.inputScope {
      opened.surface.editor.select(
        CursorList(cursors[0], others: Array(cursors.dropFirst())), reveal: .none)
    }
  }

  /// ⌘D で足した一致が見えていなければ、その行を中央へ送る。見えていれば動かさない。
  func testAddingTheNextOccurrenceCentersItOnlyWhenHidden() throws {
    let near = try opened("needle", at: [0, 5, 200])
    let text = near.document.text
    place(near, [.selecting(NSRange(location: 0, length: 6))])
    near.surface.textView.addSelectionToNextFindMatch(nil)
    XCTAssertEqual(near.surface.viewportLines.first, 0, "見えている一致では動かない")
    near.surface.textView.addSelectionToNextFindMatch(nil)
    XCTAssertEqual(near.surface.cursorSelections.last?.location, text.lineStart(200))
    let (first, visible) = near.surface.viewportLines
    XCTAssertEqual(first + visible / 2, 200.5, accuracy: 0.01, "画面外の一致は中央へ")
  }

  /// ⌥⌘↑ はいちばん上の、⌥⌘↓ はいちばん下のカーソルが見えるところまで送る（主ではなく）。
  func testInsertingCursorsRevealsTheOuterMostCursor() throws {
    let opened = try opened("x", at: [])
    let surface = opened.surface
    let text = opened.document.text
    place(opened, [Cursor(text.lineStart(100))])
    surface.scroll(toFirstLine: 100)
    surface.textView.insertCursorAbove(nil)
    XCTAssertEqual(surface.viewportLines.first, 99, accuracy: 0.01, "上に足したカーソルの行まで")
    let visible = surface.viewportLines.visible
    surface.scroll(toFirstLine: 100 - visible + 1)
    let before = surface.viewportLines.first
    surface.textView.insertCursorBelow(nil)
    XCTAssertGreaterThan(surface.viewportLines.first, before, "下に足したカーソルの行まで")
    XCTAssertLessThanOrEqual(surface.viewportLines.first, 101)
  }

  /// ⌥クリックは足したカーソルを見せ、画面外にある主へは飛ばない。
  func testOptionClickDoesNotJumpToAHiddenPrimary() throws {
    let opened = try opened("x", at: [])
    place(opened, [Cursor(opened.document.text.lineStart(200))])
    try click(opened, row: 1, column: 0, flags: .option)
    XCTAssertEqual(opened.surface.cursorSelections.count, 2)
    XCTAssertEqual(opened.surface.viewportLines.first, 0)
  }

  /// 打鍵は、画面外にある主のキャレットを見せる。
  func testTypingRevealsThePrimaryCaret() throws {
    let opened = try opened("x", at: [])
    let text = opened.document.text
    place(opened, [Cursor(text.lineStart(200)), Cursor(text.lineStart(1))])
    opened.surface.textView.insertText("y")
    let (first, visible) = opened.surface.viewportLines
    XCTAssertLessThanOrEqual(first, 200)
    XCTAssertGreaterThan(first + visible, 200, "主の行が見える")
  }
}
