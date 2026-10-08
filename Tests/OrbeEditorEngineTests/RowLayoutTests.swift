import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 縦の並びの式——文書の行と差し込みの塊の y、y にある項目、縦の端。壊れると、差し込みのある面で本文・行番号・キャレット・
/// 当たりが別の行の位置に出る、差し込みの無い面の位置が 1 画素でもずれる。
final class RowLayoutTests: XCTestCase {
  private let lineHeight = 18.0

  /// 境 2 に 2 行、境 5 に区画（30pt）、最終行（10 行）の後に 1 行。
  private func layout() -> RowLayout {
    var rows = RowLayout(lineHeight: lineHeight)
    rows.replace([
      .init(line: 2, height: 36, content: .lines([InsertedLine("a"), InsertedLine("b")])),
      .init(line: 5, height: 30, content: .zone(ObjectIdentifier(NSObject()))),
      .init(line: 10, height: 18, content: .lines([InsertedLine("tail")])),
    ])
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
    XCTAssertEqual(rows.item(atY: 18 * 4.5), .line(4))
    XCTAssertEqual(rows.item(atY: -3), .line(-1), "上の外は負の行")
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
    XCTAssertEqual(rows.item(atY: 2 * 18 + 36), .line(2))
    XCTAssertEqual(rows.item(atY: rows.top(ofBlock: 1) + 29), .block(1))
    XCTAssertEqual(rows.line(atY: rows.top(ofBlock: 1) + 29), 5, "塊の上は次の文書の行")
    XCTAssertEqual(rows.lines(from: 2 * 18 + 5, to: 2 * 18 + 40, lineCount: 10), 2...2)
    XCTAssertNil(rows.lines(from: 2 * 18 + 5, to: 2 * 18 + 30, lineCount: 10), "塊だけが見えている")
    XCTAssertEqual(rows.blocks(from: 0, to: 2 * 18 + 1), 0..<1)
    XCTAssertEqual(rows.blocks(from: 2 * 18 + 36, to: rows.y(ofLine: 5)), 1..<2)
  }

  /// 縦の端は最後の項目の上端——最終行の後の塊があれば、その最後の行。
  func testTheEndIsTheTopOfTheLastItem() {
    let rows = layout()
    XCTAssertEqual(rows.lastTop(lineCount: 10), 10 * 18 + 36 + 30)
    XCTAssertEqual(rows.contentLines(lineCount: 10), 10 + 66.0 / 18 + 1)
    XCTAssertEqual(rows.totalHeight(lineCount: 10), 10 * 18 + 36 + 30 + 18)
    XCTAssertEqual(rows.item(atY: rows.lastTop(lineCount: 10) + 1), .block(2))
    XCTAssertEqual(rows.item(atY: rows.totalHeight(lineCount: 10)), .line(10), "最後の項目より下")
  }

  /// 最終行の後の区画が行より高ければ、端はその下端の 1 行が最上段に来る所——区画の下側まで送れる。
  func testTheEndReachesTheBottomOfATallTrailingZone() {
    var rows = RowLayout(lineHeight: lineHeight)
    rows.replace([.init(line: 10, height: 500, content: .zone(ObjectIdentifier(NSObject())))])
    XCTAssertEqual(rows.lastTop(lineCount: 10), 10 * 18 + 500 - 18)
    XCTAssertEqual(rows.contentLines(lineCount: 10), 10 + 500.0 / 18, accuracy: 1e-9)
    XCTAssertEqual(rows.lastTop(lineCount: 10) + lineHeight, rows.totalHeight(lineCount: 10))
  }
}
