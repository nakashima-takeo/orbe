import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 複数カーソルのコピー・ペーストのうち、VS Code の正解表（`VSCodeMultiCursorCases`）に無い規則。壊れると、`\r` で
/// 区切った外の行がカーソルごとに配られない・選択と同じ行の空のカーソルが行を二重に写す。
extension SurfaceClipboardTests {
  /// 外から写した文字列は `\r` だけの改行でも行に割って配り、カーソルが 1 本なら配らない。
  func testExternalLinesSplitOnALoneCarriageReturnAndNeedSeveralCursors() {
    XCTAssertEqual(
      ClipboardText.distribution("a\rb", pieces: nil, entireLine: false, cursors: 2), ["a", "b"])
    XCTAssertNil(ClipboardText.distribution("a\nb", pieces: nil, entireLine: false, cursors: 1))
  }

  /// 選択のあるカーソルと空のカーソルが混ざれば、空のカーソルは行を改行込みで写す（選択の始まりと同じ行の空のカーソルは
  /// 写さない）。
  func testMixedCursorsCopyLinesForTheEmptyOnes() {
    let text = TextRope("ab\ncd\nef\n")
    let cursors = CursorList(
      .selecting(NSRange(location: 0, length: 1)),
      others: [Cursor(2), Cursor(4), .selecting(NSRange(location: 6, length: 2))])
    let copied = ClipboardText.copy(cursors, text, lineBreak: .lf)
    XCTAssertEqual(copied.pieces, ["a", "cd\n", "ef"])
    XCTAssertEqual(copied.text, "a\ncd\n\nef")
  }
}
