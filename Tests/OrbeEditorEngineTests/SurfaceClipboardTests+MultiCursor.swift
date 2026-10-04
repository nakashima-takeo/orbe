import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 複数カーソルのコピー・ペースト（VS Code の `multiCursorPaste: spread`）。壊れると、写した選択が同じ数のカーソルへ
/// 1 つずつ配られない・写した中身の改行で配り方が崩れる・外から写した行がカーソルごとに配られない・数が合わないのに
/// 配って字が欠ける。
extension SurfaceClipboardTests {
  /// 選択を 2 つ以上写すと、平文は文書の順に改行でつないだもので、断片も載る。同じ数のカーソルへ貼ると 1 つずつ文書の
  /// 順に配られ（写した中身に改行があっても崩れない）、数が違えば各カーソルに全体が入る。
  func testCopiedSelectionsAreDistributedToTheSameNumberOfCursors() throws {
    let opened = try open("a-1\nb\n2 c d e\n")
    _ = host(opened)
    let board = privatePasteboard(opened)
    let view = opened.surface.textView
    let surface = opened.surface
    surface.inputScope {
      surface.editor.select(
        CursorList(
          .selecting(NSRange(location: 4, length: 3)),
          others: [.selecting(NSRange(location: 0, length: 1))]), reveal: .none)
    }
    view.copy(nil)
    XCTAssertEqual(board.string(forType: .string), "a\nb\n2")
    XCTAssertEqual(
      board.propertyList(forType: MetalTextView.piecesType) as? [String], ["a", "b\n2"],
      "文書の順の断片")
    surface.inputScope {
      surface.editor.select(CursorList(Cursor(12), others: [Cursor(10)]), reveal: .none)
    }
    view.paste(nil)
    XCTAssertEqual(text(opened.document), "a-1\nb\n2 c ad b\n2e\n")
    let before = text(opened.document)
    surface.inputScope {
      surface.editor.select(
        CursorList(Cursor(0), others: [Cursor(1), Cursor(2), Cursor(3)]), reveal: .none)
    }
    view.paste(nil)
    let whole = "a\nb\n2"
    XCTAssertEqual(
      text(opened.document),
      whole + "a" + whole + "-" + whole + "1" + whole + before.dropFirst(3), "数が違えば全体が入る")
  }

  /// Orbe の外から写した文字列でも、末尾の改行 1 つを除いた行の数がカーソルの数と同じなら 1 行ずつ配る。行ごと写した印が
  /// あれば配らない。
  func testExternalLinesSpreadAcrossCursors() throws {
    let opened = try open("x y z\n")
    _ = host(opened)
    let board = privatePasteboard(opened)
    board.declareTypes([.string], owner: nil)
    board.setString("1\r\n2\r\n3\r\n", forType: .string)
    let surface = opened.surface
    surface.inputScope {
      surface.editor.select(CursorList(Cursor(5), others: [Cursor(1), Cursor(3)]), reveal: .none)
    }
    surface.textView.paste(nil)
    XCTAssertEqual(text(opened.document), "x1 y2 z3\n")
    XCTAssertEqual(
      surface.cursorSelections, [8, 2, 5].map { NSRange(location: $0, length: 0) },
      "キャレットは入れた文字列の末尾")
    XCTAssertNil(
      ClipboardText.distribution("a\nb\n", pieces: nil, entireLine: true, cursors: 2),
      "行ごと写した印があれば配らない")
    XCTAssertEqual(
      ClipboardText.distribution("a\rb", pieces: nil, entireLine: false, cursors: 2), ["a", "b"])
    XCTAssertNil(ClipboardText.distribution("a\nb", pieces: nil, entireLine: false, cursors: 1))
  }

  /// 選択の無いカーソルが複数なら、各カーソルの行（同じ行は 1 回）を改行込みの断片として写し、平文は断片を改行でつなぐ
  /// （VS Code の `getPlainTextToCopy`）。同じカーソルへ貼ると 1 行ずつ配られ、行が複製される。
  func testEmptyCursorsCopyTheirLinesAsPieces() throws {
    let opened = try open("line1\nline2\nline3")
    _ = host(opened)
    let board = privatePasteboard(opened)
    let view = opened.surface.textView
    let surface = opened.surface
    let carets = { CursorList(Cursor(0), others: [Cursor(6), Cursor(8)]) }
    surface.inputScope { surface.editor.select(carets(), reveal: .none) }
    view.copy(nil)
    XCTAssertEqual(board.string(forType: .string), "line1\n\nline2\n")
    XCTAssertEqual(
      board.propertyList(forType: MetalTextView.piecesType) as? [String], ["line1\n", "line2\n"])
    surface.inputScope {
      surface.editor.select(CursorList(Cursor(0), others: [Cursor(6)]), reveal: .none)
    }
    view.paste(nil)
    XCTAssertEqual(text(opened.document), "line1\nline1\nline2\nline2\nline3")
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
