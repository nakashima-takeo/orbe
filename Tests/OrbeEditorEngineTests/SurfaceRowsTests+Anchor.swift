import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 差し込みの境は「行 r−1 の後」——上の行の中身の終わりに付く。壊れると、コメントの付いた行の行末で Enter を押すとスレッドが
/// 新しい空の行の下へ離れる・行頭の Enter で区画が動く・CRLF の文書だけ振る舞いが変わる・編集の知らせの中で置き直した
/// 差し込みが知らせの後にもう一度ずれる・複数カーソルで打つとスレッドが別の行へ飛ぶ。
extension SurfaceRowsTests {
  /// 境 `boundaries`（既定は境 0 と境 5——行 4 の後）を持つ、ミニマップを出さない 20 行の面。
  private func anchored(_ text: String? = nil, at boundaries: [Int] = [0, 5]) throws -> Opened {
    let opened = try open(text ?? rows(20), size: CGSize(width: 600, height: 400))
    opened.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    opened.surface.setRows(
      SurfaceRows(
        insertions: boundaries.map {
          RowInsertion(line: $0, content: .lines([InsertedLine("inserted \($0)")]))
        }))
    return opened
  }

  private func place(_ opened: Opened, row: Int, column: Int) {
    let text = opened.document.text
    opened.surface.selectedRange = NSRange(location: text.lineStart(row) + column, length: 0)
  }

  /// 行 4 の行末と行 5 の行頭のどちらで Enter を押しても、境は行 4 の後に残る（新しい空の行は境の下）。行 4 の途中で割れば、
  /// 割れた後の最後の行の後へ動く。境 0 はどの編集でも動かない。
  func testEnterAtTheEndOfTheLineAboveAndAtTheStartOfTheLineBelowKeepsTheBoundary() throws {
    let opened = try anchored()
    let surface = opened.surface
    let lineEnd = opened.document.text.lineStart(5) - 1 - opened.document.text.lineStart(4)
    place(opened, row: 4, column: lineEnd)
    surface.textView.insertNewline(nil)
    XCTAssertEqual(surface.rows.boundaries, [0, 5], "行末の Enter: 区画は行 4 の直後に残る")
    place(opened, row: 6, column: 0)
    surface.textView.insertNewline(nil)
    XCTAssertEqual(surface.rows.boundaries, [0, 5], "境の下の行の行頭の Enter も動かさない")
    place(opened, row: 4, column: 2)
    surface.textView.insertNewline(nil)
    XCTAssertEqual(surface.rows.boundaries, [0, 6], "行 4 を割れば、割れた後の最後の行の後")
    place(opened, row: 0, column: 0)
    surface.textView.insertNewline(nil)
    XCTAssertEqual(surface.rows.boundaries, [0, 7], "先頭の境は動かず、下の境は行の増減だけずれる")
    XCTAssertEqual(surface.drawn.rows.boundaries, [0, 7], "描く材料も同じ並び")
  }

  /// 付き先から始まる削除（行 4 の改行を消して行 5 をつなぐ）では動かず、付き先をまたいで消せば、消した区間の始まりの行の
  /// 後へ寄る。
  func testDeletingAcrossTheAnchorMovesTheBoundaryAfterTheStartLine() throws {
    let opened = try anchored()
    let surface = opened.surface
    let text = opened.document.text
    surface.selectedRange = NSRange(location: text.lineStart(5) - 1, length: 1)
    surface.textView.deleteBackward(nil)
    XCTAssertEqual(surface.rows.boundaries, [0, 5], "付き先から始まる削除では動かない")
    let joined = opened.document.text
    surface.selectedRange = NSRange(
      location: joined.lineStart(2) + 1, length: joined.lineStart(7) - joined.lineStart(2) - 1)
    surface.textView.deleteBackward(nil)
    XCTAssertEqual(surface.rows.boundaries, [0, 3], "付き先を消せば、消した区間の始まりの行 2 の後")
  }

  /// CRLF の文書でも、付き先は CR の手前——行末の Enter（CRLF を挿す）で境は動かない。
  func testTheAnchorOfACRLFLineIsBeforeTheCarriageReturn() throws {
    let opened = try anchored(rows(20).replacingOccurrences(of: "\n", with: "\r\n"))
    let text = opened.document.text
    opened.surface.selectedRange = NSRange(location: text.lineStart(5) - 2, length: 0)
    opened.surface.textView.insertNewline(nil)
    XCTAssertTrue(self.text(opened.document).contains("\r\n\r\n"), "前提: CRLF の改行を挿した")
    XCTAssertEqual(opened.surface.rows.boundaries, [0, 5])
  }

  /// 編集の知らせ（文書の本文の変化）の中で、載せる側が編集後の写しの行で差し込みを置き直すと、その並びがそのまま残る
  /// （知らせの後に面がもう一度ずらさない）。範囲の前提条件も編集後の写しの行数で検める（増えた最終行の後に置ける）。
  func testRowsPlacedInsideTheEditNoticeAreNotShiftedAgain() throws {
    let opened = try anchored()
    let surface = opened.surface
    var placed: [Int] = []
    opened.document.onTextChange = { [weak document = opened.document] _ in
      guard let document, placed.isEmpty else { return }
      placed = [3, document.text.lineCount]
      surface.setRows(
        SurfaceRows(
          insertions: placed.map {
            RowInsertion(line: $0, content: .lines([InsertedLine("again \($0)")]))
          }))
    }
    place(opened, row: 1, column: 0)
    surface.perform(.insert("one\ntwo\n"))
    XCTAssertEqual(placed.last, 23, "前提: 編集後の写しの行数で置いた")
    XCTAssertEqual(surface.rows.boundaries, placed, "知らせの中で置いた並びは、もうずれない")
    XCTAssertEqual(surface.drawn.rows.boundaries, placed)
  }

  /// 複数カーソルの Enter（1 つの編集の束）でも、境はそれぞれ自分の付き先で動く——前のカーソルが足した行の分だけずれ、
  /// 付き先にいるカーソルでは動かず、付き先を消した選択では消した区間の始まりの行（前で足した行を数えて）の後へ寄る。
  func testEnterWithSeveralCursorsMovesEachBoundaryByItsOwnAnchor() throws {
    let opened = try anchored(at: [0, 5, 10, 15])
    let text = opened.document.text
    let removed = NSRange(
      location: text.lineStart(8) + 2, length: text.lineStart(12) - text.lineStart(8))
    opened.surface.inputScope {
      opened.surface.editor.select(
        CursorList(
          Cursor(text.lineStart(3) - 1),
          others: [Cursor(text.lineStart(5) - 1), .selecting(removed)]),
        reveal: .none)
    }
    opened.surface.textView.insertNewline(nil)
    XCTAssertEqual(
      opened.surface.rows.boundaries, [0, 6, 11, 14],
      "行 4 の後は行 2 の改行で 1 つ下へ・行 9 の後は消した区間の始まりの行 8（2 つ下がって 10）の後・行 14 の後は 3 行足して 4 行消した分")
    XCTAssertEqual(opened.surface.drawn.rows.boundaries, [0, 6, 11, 14], "描く材料も同じ並び")
  }
}
