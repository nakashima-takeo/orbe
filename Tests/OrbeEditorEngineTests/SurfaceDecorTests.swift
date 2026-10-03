import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 面の行の装備——空白の丸点・URL の下線（規則は Core の純関数）と、タブの表示幅。壊れるとタブが違う幅で開く・
/// 単語間の空白に点が出る・下線が URL からずれる・選択が装備を覆わない。
@MainActor
final class SurfaceDecorTests: EngineTestCase {
  private let style = EngineTestCase.style()

  /// 行 `row`（0 始まり）の縦の中央（pt）。
  private func rowMidY(_ row: Int) -> CGFloat {
    style.topInset + CGFloat(row) * style.lineHeight + style.lineHeight / 2
  }

  /// 本文の桁 `column`（半角）の左端の x（pt）。
  private func x(_ opened: Opened, _ column: CGFloat) -> CGFloat {
    opened.surface.config.columnWidth(lineCount: opened.document.text.lineCount)
      + column * opened.surface.config.cell
  }

  /// タブの表示幅は文書が検出した単位（ここではスペースの行から 2 桁）——2 個のタブの後の字は 4 桁目に立つ。
  func testTabWidthFollowsTheIndentUnit() throws {
    let opened = try open("f {\n  a\n\t\tx\n}\n", name: "a.txt")
    let shot = try pixelShot(opened)
    XCTAssertEqual(opened.document.indentation.unit, 2)
    XCTAssertTrue(shot.hasInk(x(opened, 4.5), rowMidY(2)), "2 個のタブの後の字は 4 桁目")
    XCTAssertFalse(shot.hasInk(x(opened, 8.5), rowMidY(2)), "既定の 4 桁のタブなら立つ 8 桁目には無い")
  }

  /// CRLF の文書でも行末の `\r` は行の外——行末の 1 個のスペースに点が出る。
  func testCRLFLinesKeepTrailingSpaceDots() throws {
    let opened = try open("  a \r\n\r\n    b\r\n", name: "a.txt")
    let shot = try pixelShot(opened)
    XCTAssertTrue(shot.hasInk(x(opened, 3.5), rowMidY(0)), "行末の 1 個に点")
  }

  /// コメントの中の URL の下線は、そこの字と同じ comment の役割の色。
  func testLinkUnderlineInACommentTakesTheCommentColor() throws {
    let opened = try open("// see https://a.b/c now\n", name: "a.swift")
    let shot = try pixelShot(opened)
    let config = opened.surface.config
    let y = config.topInset + config.baseline + 3 + 0.25
    let comment = [107, 153, 84]
    for column: CGFloat in [7.5, 12.5, 18.5] {
      let ink = shot.rgb(x(opened, column), y)
      XCTAssertTrue(zip(ink, comment).allSatisfy { abs($0 - $1) <= 1 }, "\(column) 桁: \(ink)")
    }
  }

  /// 丸点は行頭・行末・2 個以上の連続スペースのセルの中央に出て、単語間の 1 個とタブには出ない。
  func testWhitespaceDotsOnlyAtBoundaries() throws {
    let opened = try open("  a b  c \n\td\n", name: "a.txt")
    let shot = try pixelShot(opened)
    let dot = { (column: CGFloat) in shot.hasInk(self.x(opened, column + 0.5), self.rowMidY(0)) }
    XCTAssertTrue(dot(0) && dot(1), "行頭")
    XCTAssertFalse(dot(3), "単語間の 1 個")
    XCTAssertTrue(dot(5) && dot(6), "2 個の連続")
    XCTAssertTrue(dot(8), "行末")
    XCTAssertFalse(shot.hasInk(x(opened, 2), rowMidY(1)), "タブには無い")
  }

  /// URL の下線は区間の左端から右端まで、基線の 3 下に文字と同じ色で引く。末尾の句読点には引かない。
  func testLinkUnderlineRunsBelowTheURLInTheTextsColor() throws {
    let opened = try open("see https://example.com/a. ok\n", name: "a.txt")
    let shot = try pixelShot(opened)
    let config = opened.surface.config
    let y = config.topInset + config.baseline + 3 + 0.25
    XCTAssertEqual(shot.rgb(x(opened, 10.5), y), [204, 204, 204], "URL の中は文字の色")
    XCTAssertFalse(shot.hasInk(x(opened, 3.5), y), "URL の前には無い")
    XCTAssertFalse(shot.hasInk(x(opened, 25.5), y), "末尾の句読点には無い")
  }

  /// 選択の地は装備を覆う（選択中の行の点は見えない）。
  func testSelectionCoversTheDecorations() throws {
    let opened = try open("    a\n", name: "a.txt")
    opened.surface.selectedRange = NSRange(location: 0, length: 5)
    let shot = try pixelShot(opened)
    XCTAssertEqual(shot.rgb(x(opened, 1.5), rowMidY(0)), [59, 61, 66], "点の上も選択の色（焦点が無いので弱い色）")
  }
}
