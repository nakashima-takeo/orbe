import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 差し込み（文書に無い行）のある面——描く位置・当たり・スクロールの範囲と操作・見えている先頭の文書の行の保持・面自身の
/// 編集での境の追従。壊れると、差し込みの下の本文や行番号や印が差し込みに重なる、差し込んだ行を押すと別の行に当たる、
/// diff を取り直すたびに画面が跳ねる、打鍵で差し込みが別の行へずれる。
@MainActor
final class SurfaceRowsTests: EngineTestCase {
  let size = CGSize(width: 600, height: 400)

  /// ミニマップを出さない面に `count` 行（行 i は「row i 」と x の並び）。
  func openRows(_ count: Int = 80) throws -> Opened {
    let opened = try open(rows(count), size: size)
    opened.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    return opened
  }

  func insert(_ lines: [String], at line: Int) -> RowInsertion {
    RowInsertion(line: line, content: .lines(lines.map { InsertedLine($0) }))
  }

  /// 文書に無い行は本文の色で描かれ、行番号を持たない。下の文書の行（本文・行番号・git の印・選択の地・強調の地）は差し込みの
  /// 高さだけ下に描かれ、上の行は動かない。
  func testInsertedLinesPushTheLinesBelowDown() throws {
    let opened = try openRows()
    let text = opened.document.text
    var baseline = self.text(opened.document).components(separatedBy: "\n")
    for row in [1, 4, 6] { baseline[row] = "old \(row)" }
    baseline.insert("gone", at: 8)
    opened.document.baseline = baseline.joined(separator: "\n")
    XCTAssertTrue(opened.document.waitUntilCaughtUp())
    XCTAssertFalse(opened.surface.drawn.marks.bars.isEmpty, "前提: 上と下の印・削除の印が届いている")
    opened.surface.selectedRange = NSRange(
      location: text.lineStart(1) + 2, length: text.lineStart(6) + 4 - text.lineStart(1) - 2)
    opened.surface.setHighlights([NSRange(location: text.lineStart(5), length: 3)], for: .findMatch)
    let before = try pixelShot(opened)
    opened.surface.setRows(
      SurfaceRows(insertions: [insert(["- removed one", "- removed two"], at: 3)]))
    let after = try pixelShot(opened)
    let config = opened.surface.config
    let right = Int(opened.surface.surfaceLayout.text.maxX * 2)
    let column = config.columnWidth(lineCount: opened.document.text.lineCount)
    let split = Int((config.topInset + 3 * config.lineHeight) * 2)
    let shift = Int(2 * config.lineHeight * 2)
    XCTAssertEqual(rowsDiffer(before, after, x: 0..<right, y: 0..<split, dy: 0), 0, "上の行は動かない")
    XCTAssertEqual(
      rowsDiffer(before, after, x: 0..<right, y: split..<(after.height - shift), dy: shift), 0,
      "下の行は本文も行番号も差し込みの高さだけ下がる")
    XCTAssertTrue(
      stride(from: column, to: column + 60, by: 0.5).contains {
        after.hasInk($0, config.topInset + 3.5 * config.lineHeight)
      }, "差し込んだ行の字が描かれる")
    XCTAssertFalse(
      stride(from: 0, to: column - config.marks.gutterWidth, by: 0.5).contains {
        after.hasInk($0, config.topInset + 3.5 * config.lineHeight)
          || after.hasInk($0, config.topInset + 4.5 * config.lineHeight)
      }, "差し込んだ行には行番号が無い")
  }

  /// 差し込んだ行を押すと次の文書の行の行頭に当たり、字には当たらない。最終行の後の差し込みは本文の終わり。
  func testInsertedLinesHitTheStartOfTheNextLine() throws {
    let opened = try openRows(10)
    opened.surface.setRows(
      SurfaceRows(insertions: [insert(["- gone"], at: 3), insert(["- tail"], at: 10)]))
    let config = opened.surface.config
    let inserted = CGPoint(
      x: config.columnWidth(lineCount: 10) + 2 * config.cell,
      y: config.topInset + 3.5 * config.lineHeight)
    let text = opened.document.text
    XCTAssertEqual(opened.surface.hit(inserted)?.offset, text.lineStart(3))
    XCTAssertNil(opened.surface.character(at: inserted), "差し込んだ行の字には当たらない")
    let below = CGPoint(x: inserted.x, y: config.topInset + 4.5 * config.lineHeight)
    XCTAssertEqual(opened.surface.hit(below)?.row, 3, "差し込みの下は 1 行ずれた文書の行")
    let tail = CGPoint(x: inserted.x, y: config.topInset + 11.5 * config.lineHeight)
    XCTAssertEqual(opened.surface.hit(tail)?.offset, text.length, "最終行の後の差し込みは本文の終わり")
  }

  /// 見えている先頭の文書の行より上で差し込みが増減しても、その行の画面上の位置は変わらない。下の差し込みでは動かない。
  func testRowsAboveTheViewportKeepTheFirstVisibleLineInPlace() throws {
    let opened = try openRows()
    let surface = opened.surface
    surface.scroll(toFirstLine: 30.25)
    surface.flush()
    let offset = surface.scrollPosition.y - surface.rows.y(ofLine: 30)
    let viewport = surface.viewport
    surface.setRows(SurfaceRows(insertions: [insert(["a", "b", "c"], at: 10)]))
    surface.flush()
    XCTAssertEqual(surface.scrollPosition.y - surface.rows.y(ofLine: 30), offset, accuracy: 1e-9)
    XCTAssertEqual(surface.viewport, viewport, "見えている範囲は同じ")
    let placed = surface.scrollPosition.y
    surface.setRows(
      SurfaceRows(insertions: [insert(["a", "b", "c"], at: 10), insert(["d"], at: 70)]))
    surface.flush()
    XCTAssertEqual(surface.scrollPosition.y, placed, "下の差し込みでは動かない")
    surface.setRows(SurfaceRows())
    surface.flush()
    XCTAssertEqual(surface.scrollPosition.y - surface.rows.y(ofLine: 30), offset, accuracy: 1e-9)
  }

  /// 端の外へ引っ張っている最中に上で差し込みが増えても、端に収めずに弾みが続き（最終行からの位置は保つ）、離せば新しい
  /// 端へ戻る。
  func testRowsChangedWhileBouncingKeepTheBounce() throws {
    let opened = try openRows()
    let surface = opened.surface
    let lineCount = opened.document.text.lineCount
    surface.scrollToDocumentEdge(end: true)
    surface.scroll(toFirstLine: 1e9)
    surface.flush()
    surface.scroll(ScrollInput(timestamp: 1, delta: .zero, precise: true, phase: .began))
    surface.scroll(
      ScrollInput(timestamp: 1.01, delta: SIMD2(0, -200), precise: true, phase: .changed))
    let beyond = surface.scrollPosition.y - surface.rows.y(ofLine: lineCount - 1)
    XCTAssertGreaterThan(beyond, 0, "前提: 最後の行より先へ引っ張っている")
    surface.setRows(SurfaceRows(insertions: [insert(["a", "b"], at: 10)]))
    surface.flush()
    XCTAssertEqual(
      surface.scrollPosition.y - surface.rows.y(ofLine: lineCount - 1), beyond, accuracy: 1e-9,
      "端に収めない")
    surface.scroll(ScrollInput(timestamp: 1.02, delta: .zero, precise: true, phase: .ended))
    XCTAssertEqual(
      surface.scroll.peek(at: 3).position.y, surface.rows.lastTop(lineCount: lineCount),
      accuracy: 0.5, "離せば新しい端へ戻る")
  }

  /// 面自身の編集で、差し込みの境が上の行に付いて動く——付き先（行 r−1 の中身の終わり）より後ろの編集では残り、前の編集の
  /// 行の増減の分だけ動き、付き先を消した編集では消した区間の始まりの行の後へ寄る。本文を丸ごと置き換えても、境は本文の
  /// 行の範囲に収まる。
  func testRowsFollowTheSurfaceEdits() throws {
    let opened = try openRows(20)
    let surface = opened.surface
    surface.setRows(SurfaceRows(insertions: [insert(["a"], at: 5), insert(["b"], at: 12)]))
    surface.selectedRange = NSRange(location: opened.document.text.lineStart(8), length: 0)
    surface.editor.perform(.insert("new\n"))
    XCTAssertEqual(surface.rows.boundaries, [5, 13])
    XCTAssertEqual(surface.drawn.rows.boundaries, [5, 13], "描く材料も同じ並び")
    let text = opened.document.text
    surface.selectedRange = NSRange(
      location: text.lineStart(4), length: text.lineStart(9) - text.lineStart(4))
    surface.editor.perform(.insert(""))
    XCTAssertEqual(surface.rows.boundaries, [5, 8], "付き先（行 4 の終わり）を消せば、消した区間の始まりの行 4 の後へ")
    surface.replaceAll(with: rows(3))
    let lineCount = opened.document.text.lineCount
    XCTAssertTrue(
      surface.drawn.rows.boundaries.allSatisfy { (0...lineCount).contains($0) },
      "丸ごと置き換えた後も、境は本文の行の範囲")
  }

  /// スクロールの範囲と操作は並びの高さで決まる——最後の項目（最終行の後の差し込み）を最上段まで送れ、End は最後の 1 画面、
  /// 区間を見せる着地も差し込みを数える。
  func testScrollingUsesTheHeightOfTheRows() throws {
    let opened = try openRows()
    let surface = opened.surface
    let lineCount = opened.document.text.lineCount
    surface.setRows(
      SurfaceRows(insertions: [
        insert(["a", "b", "c"], at: 20), insert(["x", "y"], at: lineCount),
      ])
    )
    let limits = surface.scrollState().limits
    XCTAssertEqual(limits.maximum.y, surface.rows.lastTop(lineCount: lineCount))
    XCTAssertEqual(
      limits.maximum.y, Double(lineCount + 3 + 1) * Double(surface.config.lineHeight),
      "最終行の後の 2 行の最後が最上段")
    surface.scrollToDocumentEdge(end: true)
    XCTAssertEqual(
      surface.scrollPosition.y, surface.rows.totalHeight(lineCount: lineCount) - limits.viewport.y)
    let text = opened.document.text
    surface.reveal(NSRange(location: text.lineStart(40), length: 0), policy: .center)
    let lineHeight = Double(surface.config.lineHeight)
    XCTAssertEqual(
      surface.rows.y(ofLine: 40) - surface.scrollPosition.y,
      (limits.viewport.y / lineHeight / 2 - 0.5) * lineHeight, accuracy: 1e-9,
      "行 40 が中央（上の 3 行を数えた位置）")
  }

  /// ページ送りは縦の並びでページの高さだけ離れた所の文書の行へ動く（差し込んだ行を数える）。
  func testPagingCountsTheInsertedRows() throws {
    let opened = try openRows()
    let surface = opened.surface
    surface.setRows(SurfaceRows(insertions: [insert(["a", "b", "c", "d"], at: 5)]))
    surface.selectedRange = NSRange(location: 0, length: 0)
    let pageLines = try XCTUnwrap(surface.bodySite.editingEnvironment()).pageLines
    surface.editor.perform(.move(.pageDown, extending: false))
    XCTAssertEqual(
      opened.document.text.row(containing: surface.caretLocation), pageLines - 4,
      "4 行の差し込みの分だけ手前の行")
  }

  /// ミニマップを出さない構成では、右列は縦スクロールバーだけで、ミニマップを描かない。
  func testWithoutTheMinimapTheRightColumnIsTheScrollbar() throws {
    let opened = try openRows()
    XCTAssertEqual(
      opened.surface.rightColumnWidth, EngineTestCase.overviewStyle().scrollbar.width)
    _ = opened.surface.snapshot()
    XCTAssertNil(opened.surface.placementBox.read(), "ミニマップを組まない")
    opened.surface.setPresentation(.code)
    XCTAssertGreaterThan(
      opened.surface.rightColumnWidth, EngineTestCase.overviewStyle().scrollbar.width)
  }

  /// `x`・`y` の画素の範囲で、`after` の行を `dy` px 下げた所と `before` が違う画素の数。
  private func rowsDiffer(
    _ before: PixelShot, _ after: PixelShot, x: Range<Int>, y: Range<Int>, dy: Int
  ) -> Int {
    var count = 0
    for row in y {
      for column in x {
        let a = (row * before.width + column) * 4
        let b = ((row + dy) * after.width + column) * 4
        if before.bytes[a..<a + 3] != after.bytes[b..<b + 3] { count += 1 }
      }
    }
    return count
  }
}
