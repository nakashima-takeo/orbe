import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 縦の並びの式——文書の行と差し込みの塊の y、y にある項目、縦の端。壊れると、差し込みのある面で本文・行番号・キャレット・
/// 当たりが別の行の位置に出る、差し込みの無い面の位置が 1 画素でもずれる。
final class RowLayoutTests: XCTestCase {
  private let lineHeight = 18.0

  /// 境 2 に 2 行、境 5 に絵の差し込み（30pt）、最終行（10 行）の後に 1 行。
  private func layout() -> RowLayout {
    var rows = RowLayout(lineHeight: lineHeight)
    rows.replace(
      [
        .init(line: 2, height: 36, content: .lines([InsertedLine(), InsertedLine()])),
        .init(line: 5, height: 30, content: .zone(ObjectIdentifier(NSObject()))),
        .init(line: 10, height: 18, content: .lines([InsertedLine()])),
      ], spans: [])
    return rows
  }

  /// 差し込みが無ければ、どの式も `行 × 行高` と同じ浮動小数の値を返す（差し込みの無い面の位置と画素は変わらない）。
  func testWithoutInsertionsEveryFormulaIsRowTimesLineHeight() {
    let rows = RowLayout(lineHeight: lineHeight)
    for row in [0, 1, 7, 999] {
      XCTAssertEqual(rows.y(ofLine: row), Double(row) * lineHeight)
      XCTAssertEqual(rows.y(ofLine: row, scale: 2), Double(row) * (lineHeight * 2))
      XCTAssertEqual(rows.unit(ofLine: row), Double(row))
    }
    XCTAssertEqual(rows.item(atY: 18 * 4.5), .line(4, segment: 0))
    XCTAssertEqual(rows.item(atY: -3), .line(-1, segment: 0), "上の外は負の行")
    XCTAssertEqual(rows.lastTop(lineCount: 100), 99 * lineHeight)
    XCTAssertEqual(rows.contentLines(lineCount: 100), 100)
    XCTAssertEqual(rows.totalHeight(lineCount: 100), 100 * lineHeight)
    XCTAssertEqual(rows.firstUnit(atY: 18 * 3 + 9, lineCount: 100), 3.5)
    XCTAssertEqual(rows.lines(from: 18 * 2.5, to: 18 * 7, lineCount: 100), 2...7)
  }

  func testLinesAreLaidBelowTheBlocksAboveThem() {
    let rows = layout()
    XCTAssertEqual(rows.y(ofLine: 1), 18)
    XCTAssertEqual(rows.y(ofLine: 2), 2 * 18 + 36, "境 2 の塊は行 2 の上")
    XCTAssertEqual(rows.top(ofBlock: 0), 2 * 18)
    XCTAssertEqual(rows.y(ofLine: 5), 5 * 18 + 36 + 30)
    XCTAssertEqual(rows.unit(ofLine: 5), 5 + 66.0 / 18)
    XCTAssertEqual(rows.item(atY: 2 * 18 + 10), .block(0))
    XCTAssertEqual(rows.item(atY: 2 * 18 + 36), .line(2, segment: 0))
    XCTAssertEqual(rows.item(atY: rows.top(ofBlock: 1) + 29), .block(1))
    XCTAssertEqual(rows.line(atY: rows.top(ofBlock: 1) + 29), 5, "塊の上は次の文書の行")
    XCTAssertEqual(rows.lines(from: 2 * 18 + 5, to: 2 * 18 + 40, lineCount: 10), 2...2)
    XCTAssertNil(rows.lines(from: 2 * 18 + 5, to: 2 * 18 + 30, lineCount: 10), "塊だけが見えている")
    XCTAssertEqual(rows.blocks(from: 0, to: 2 * 18 + 1), 0..<1)
    XCTAssertEqual(rows.blocks(from: 2 * 18 + 36, to: rows.y(ofLine: 5)), 1..<2)
  }

  /// 位置の上端に面を置いて読み直すと同じ位置に戻る——最終行の後の塊の中でも、行高の整数倍でない絵の差し込みの頭とその
  /// 下の行で表示の単位から y へ丸めても（化けると、面を作り直すたびに見えている位置が上へずれる）。
  func testAPositionSurvivesTheRoundTripThroughY() {
    let rows = layout()
    let positions =
      [
        RowPosition(line: 2, offset: -2), RowPosition(line: 5, offset: -2),
        .init(line: 5, offset: -1), .init(line: 10, offset: -1),
      ]
      + (0..<10).map { RowPosition(line: $0) }
    for position in positions {
      let y = rows.unit(of: position, lineCount: 10) * lineHeight
      XCTAssertEqual(rows.position(atY: y, lineCount: 10), position, "\(position)")
    }
  }

  /// 差し込んだ行だけを数えた段は、同じ境の絵の差し込みの高さに依らず同じ差し込んだ行を指し、位置との行き来で戻る。絵の
  /// 差し込みの中の位置は、その下の差し込んだ行の頭になる（壊れると、スレッドを置いた削除行の塊の中で面を作り直したとき、
  /// 先頭が絵の高さの段数だけ前の削除行へずれる）。
  func testALineRowCountsOnlyTheInsertedLinesOfTheBlock() {
    var rows = RowLayout(lineHeight: lineHeight)
    rows.replace(
      [
        .init(line: 4, height: 36, content: .lines([InsertedLine(), InsertedLine()])),
        .init(line: 4, height: 45, content: .zone(ObjectIdentifier(NSObject()))),
        .init(line: 4, height: 18, content: .lines([InsertedLine()])),
      ], spans: [])
    let total = (36.0 + 45 + 18) / lineHeight
    XCTAssertEqual(rows.lineRow(of: .head(of: 4)), LineRow(line: 4, offset: -3))
    XCTAssertEqual(
      rows.lineRow(of: RowPosition(line: 4, offset: Int((1.5 - total).rounded(.up)))),
      LineRow(line: 4, offset: -2), "2 つ目の差し込んだ行")
    XCTAssertEqual(
      rows.lineRow(of: RowPosition(line: 4, offset: -2)), LineRow(line: 4, offset: -1),
      "絵の差し込みの中は、その下の差し込んだ行")
    XCTAssertEqual(rows.lineRow(of: RowPosition(line: 4, offset: 0)), LineRow(line: 4))
    for offset in -3 ... -1 {
      let row = LineRow(line: 4, offset: offset)
      XCTAssertEqual(rows.lineRow(of: rows.position(ofLineRow: row)), row, "\(row)")
    }
    XCTAssertEqual(
      rows.position(ofLineRow: LineRow(line: 4, offset: -1)), RowPosition(line: 4, offset: -1))
  }

  /// 行高で割り切れない高さの絵の差し込みがあっても、差し込んだ行だけを数えた段は浮動小数の誤差で隣の行に化けない。
  func testALineRowSurvivesFractionalZoneHeights() {
    for heights in [[40.0], [96, 125.4]] {
      var rows = RowLayout(lineHeight: lineHeight)
      var blocks: [RowLayout.Block] = [
        .init(line: 4, height: 18 * 2, content: .lines([InsertedLine(), InsertedLine()]))
      ]
      for height in heights {
        blocks.append(.init(line: 4, height: height, content: .zone(ObjectIdentifier(NSObject()))))
      }
      blocks.append(
        .init(
          line: 4, height: 18 * 3,
          content: .lines([InsertedLine(), InsertedLine(), InsertedLine()])))
      rows.replace(blocks, spans: [])
      for offset in -5 ... -1 {
        let row = LineRow(line: 4, offset: offset)
        XCTAssertEqual(rows.lineRow(of: rows.position(ofLineRow: row)), row, "\(heights) \(row)")
      }
    }
  }

  /// 縦の端は最後の項目の上端——最終行の後の塊があれば、その最後の行。
  func testTheEndIsTheTopOfTheLastItem() {
    let rows = layout()
    XCTAssertEqual(rows.lastTop(lineCount: 10), 10 * 18 + 36 + 30)
    XCTAssertEqual(rows.contentLines(lineCount: 10), 10 + 66.0 / 18 + 1)
    XCTAssertEqual(rows.totalHeight(lineCount: 10), 10 * 18 + 36 + 30 + 18)
    XCTAssertEqual(rows.item(atY: rows.lastTop(lineCount: 10) + 1), .block(2))
    XCTAssertEqual(
      rows.item(atY: rows.totalHeight(lineCount: 10)), .line(10, segment: 0), "最後の項目より下")
  }

  /// 最終行の後の絵の差し込みが行より高ければ、端はその下端の 1 行が最上段に来る所——絵の差し込みの下側まで送れる。
  func testTheEndReachesTheBottomOfATallTrailingZone() {
    var rows = RowLayout(lineHeight: lineHeight)
    rows.replace(
      [.init(line: 10, height: 500, content: .zone(ObjectIdentifier(NSObject())))], spans: [])
    XCTAssertEqual(rows.lastTop(lineCount: 10), 10 * 18 + 500 - 18)
    XCTAssertEqual(rows.contentLines(lineCount: 10), 10 + 500.0 / 18, accuracy: 1e-9)
    XCTAssertEqual(rows.lastTop(lineCount: 10) + lineHeight, rows.totalHeight(lineCount: 10))
  }

  /// 文書の行の区間は始まりの行から次の区間の前までを指し、もう一方の番号は区間の始まりからの差で数える。番号の最大は、
  /// 差し込んだ行・途中の区間の終わり・最後の区間の最終行のどれからでも取る（2 列の面の左の列の幅になる）。
  func testLineSpansIndexTheLinesAndTheLargestOtherNumber() {
    var rows = RowLayout(lineHeight: lineHeight)
    let inserted = RowLayout.Block(
      line: 4, height: lineHeight, content: .lines([InsertedLine(line: 99)]))
    rows.replace(
      [inserted],
      spans: [
        LineSpan(line: 2, style: 0, otherNumber: 10), LineSpan(line: 5, otherNumber: 300),
        LineSpan(line: 9, style: 1, otherNumber: 20),
      ])
    XCTAssertEqual(
      [1, 2, 4, 5, 8, 9, 30].map { rows.span(containing: $0) }, [nil, 0, 0, 1, 1, 2, 2])
    XCTAssertEqual([1, 2, 4, 5, 9].map { rows.style(ofLine: $0) }, [nil, 0, 0, nil, 1])
    XCTAssertEqual([1, 4, 8, 9, 12].map { rows.otherNumber(ofLine: $0) }, [nil, 12, 303, 20, 23])
    XCTAssertEqual(rows.otherNumberMax(lineCount: 12), 303, "途中の区間の終わり")
    XCTAssertEqual(rows.otherNumberMax(lineCount: 400), 410, "最後の区間の最終行")
    rows.replace(
      [inserted], spans: [LineSpan(line: 5, otherNumber: 30), LineSpan(line: 9, otherNumber: 20)])
    XCTAssertEqual(rows.otherNumberMax(lineCount: 12), 100, "差し込んだ行")
    XCTAssertEqual(rows.otherNumberMax(lineCount: 9), 100, "最後の区間に行が無い")
  }
}
