import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面の行の装備——インデント線・空白の丸点・URL の下線（規則は今の面と同じ Core の純関数）。壊れると線が段の途中に
/// 立つ・空行の線が途切れる・単語間の空白に点が出る・下線が URL からずれる・選択が装備を覆わない。
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

  /// 線は段の境の字の左端に段の数だけ立ち、空白だけの行は前後の非空行の浅い方まで続く。0 段の行には無い。
  func testIndentGuidesStandAtTheUnitColumnsAndBlankLinesTakeTheShallowerNeighbour() throws {
    let opened = try open("f {\n  a\n    b\n\n      c\n  d\n}\n", name: "a.txt")
    let shot = try pixelShot(opened)
    XCTAssertEqual(opened.document.indentation.unit, 2)
    let guide = { (level: Int) in self.x(opened, CGFloat(level * 2)) + 0.25 }
    XCTAssertTrue(shot.hasInk(guide(1), rowMidY(1)), "1 段の行に段 1 の線")
    XCTAssertFalse(shot.hasInk(guide(2), rowMidY(1)), "1 段の行に段 2 の線は無い")
    XCTAssertTrue(shot.hasInk(guide(1), rowMidY(4)) && shot.hasInk(guide(3), rowMidY(4)), "3 段の行")
    XCTAssertTrue(shot.hasInk(guide(2), rowMidY(3)), "空行は隣（2 段と 3 段）の浅い方＝2 段")
    XCTAssertFalse(shot.hasInk(guide(3), rowMidY(3)), "空行に段 3 の線は無い")
    XCTAssertFalse(shot.hasInk(guide(1), rowMidY(6)), "0 段の行には無い")
  }

  /// 空白だけの行の段は、見えている範囲の外の非空行からも決まる（上へ送って空行だけが見えていても線が続く）。
  func testBlankLinesTakeNeighboursBeyondTheVisibleRows() throws {
    let blank = String(repeating: "\n", count: 60)
    let opened = try open(
      "f {\n    a" + blank + "    b\n}\n", name: "a.txt", size: CGSize(width: 400, height: 200))
    opened.surface.scroll(toFirstLine: 20)
    let shot = try pixelShot(opened)
    XCTAssertTrue(shot.hasInk(x(opened, 4) + 0.25, rowMidY(2)), "上下の外の 1 段の行から段 1")
  }

  /// タブで書かれた文書では、空白だけの行の線（桁から置く）がタブの行の線（字の位置から置く）と同じ x に立つ——タブの
  /// 表示幅が検出した単位（スペースの行が無ければ 4 桁）なので。
  func testTabWidthFollowsTheIndentUnitSoBlankLineGuidesAlign() throws {
    let opened = try open("\tif {\n\n\t\tx\n\t}\n", name: "a.txt")
    let shot = try pixelShot(opened)
    XCTAssertEqual(opened.document.indentation.unit, 4)
    XCTAssertTrue(shot.hasInk(x(opened, 4) + 0.25, rowMidY(2)), "タブの行の段 1 は 4 桁目")
    XCTAssertTrue(shot.hasInk(x(opened, 4) + 0.25, rowMidY(1)), "空行の線が同じ x に立つ")
    XCTAssertFalse(shot.hasInk(x(opened, 8) + 0.25, rowMidY(1)), "空行は隣の浅い方（1 段）")
  }

  /// CRLF の文書でも行末の `\r` は行の外——行末の 1 個のスペースに点が出て、空行（`\r` だけ）の線が隣から続く。
  func testCRLFLinesKeepTrailingSpaceDotsAndBlankLineGuides() throws {
    let opened = try open("  a \r\n\r\n    b\r\n", name: "a.txt")
    let shot = try pixelShot(opened)
    XCTAssertEqual(opened.document.indentation.unit, 2)
    XCTAssertTrue(shot.hasInk(x(opened, 3.5), rowMidY(0)), "行末の 1 個に点")
    XCTAssertTrue(shot.hasInk(x(opened, 2) + 0.25, rowMidY(1)), "空行に隣の浅い方（1 段）の線")
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

  /// 選択の地は装備を覆う（選択中の行の点や線は見えない）。
  func testSelectionCoversTheDecorations() throws {
    let opened = try open("    a\n", name: "a.txt")
    opened.surface.selectedRange = NSRange(location: 0, length: 5)
    let shot = try pixelShot(opened)
    XCTAssertEqual(shot.rgb(x(opened, 1.5), rowMidY(0)), [59, 61, 66], "点の上も選択の色（焦点が無いので弱い色）")
  }
}
