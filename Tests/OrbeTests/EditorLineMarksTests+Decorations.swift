import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 本文の装備——インデント線・タブ幅・丸点・URL 下線。
extension EditorLineMarksTests {

  /// インデント線は行頭から段の単位ぶんの文字の左端に、段の数だけ立つ（単位は本文から検出）。空行は隣の浅い方。
  /// 線の有無は、その桁が空白か行の外にある位置で読む——字のあるセルの左端は、字の縁の画素が乗るかどうかが
  /// 倍率と桁で変わり、線の証人にならない。
  func testIndentGuidesStandAtTheUnitColumns() throws {
    let hosted = try host("f {\n  a\n    b\n\n      c\n  d\n}\n")
    let ground = hosted.ground
    let guide1 = bodyX + 2 * cell
    let guide2 = bodyX + 4 * cell
    let guide3 = bodyX + 6 * cell
    waitDrawn { try self.hasInk(ground, guide2, self.rowMidY(5)) }
    XCTAssertTrue(try hasInk(ground, guide1, rowMidY(3)), "2 段の行に段 1 の線")
    XCTAssertFalse(try hasInk(ground, guide3, rowMidY(3)), "2 段の行に段 3 の線は無い")
    XCTAssertTrue(try hasInk(ground, guide1, rowMidY(5)), "3 段の行に段 1 の線")
    XCTAssertTrue(try hasInk(ground, guide2, rowMidY(5)), "3 段の行に段 2 の線")
    XCTAssertFalse(try hasInk(ground, guide2, rowMidY(2)), "1 段の行に段 2 の線は無い")
    XCTAssertTrue(try hasInk(ground, guide2, rowMidY(4)), "空行は隣（2 段と 3 段）の浅い方＝2 段")
    XCTAssertFalse(try hasInk(ground, guide3, rowMidY(4)), "空行に段 3 の線は無い")
    XCTAssertFalse(try hasInk(ground, guide1, rowMidY(7)), "0 段の行には無い")
    XCTAssertFalse(try hasInk(ground, guide2 - 2, rowMidY(4)), "線の左は地（空行なので丸点も無い）")
    XCTAssertFalse(try hasInk(ground, guide2 + 2, rowMidY(4)), "線の右は地")
  }

  /// タブで書かれた文書では、タブの表示幅が検出した単位（スペースの行が無ければ 4 桁）になり、空白だけの行の線
  /// （桁幅から置く）がタブの行の線と同じ x に立つ（AppKit 既定の 28pt 刻みのままだと段が深いほど開く）。
  func testTabWidthFollowsTheIndentUnitSoBlankLineGuidesAlign() throws {
    let hosted = try host("\tif {\n\n\t\tx\n\t}\n")
    let ground = hosted.ground
    let guide1 = bodyX + 4 * cell
    let guide2 = bodyX + 8 * cell
    waitDrawn { try self.hasInk(ground, guide1, self.rowMidY(3)) }
    XCTAssertTrue(try hasInk(ground, guide1, rowMidY(3)), "タブの行の段 1 は 4 桁目（2 個目のタブの左端）")
    XCTAssertTrue(try hasInk(ground, guide1, rowMidY(2)), "空行の線が同じ x に立つ")
    XCTAssertFalse(try hasInk(ground, guide2, rowMidY(2)), "空行は隣の浅い方（1 段）")
    XCTAssertFalse(try hasInk(ground, bodyX + 56, rowMidY(3)), "AppKit 既定の刻み（2 段目 56pt）には無い")
  }

  /// 外部で書き換えられたファイルの差し替え（本文の丸ごと置き換え）で文書はインデント単位を検出し直して面へ押し、
  /// 線の段とタブの表示幅がその単位に移る——開いたときの単位のままだと、置き換わった本文の段の途中に線が立つ。
  func testReplacingTheWholeTextRedetectsTheIndentUnitAndTabWidth() throws {
    let hosted = try host("f {\n    a\n        b\n\t\tc\n}\n")
    let ground = hosted.ground
    let col = { (n: Int) in self.bodyX + CGFloat(n) * self.cell }
    waitDrawn { try self.hasInk(ground, col(4), self.rowMidY(3)) }
    XCTAssertTrue(try hasInk(ground, col(4), rowMidY(3)), "前提: 単位 4 の段 1 の線")
    XCTAssertFalse(try hasInk(ground, col(2), rowMidY(3)))
    XCTAssertTrue(try hasInk(ground, col(4), rowMidY(4)), "前提: タブの幅も 4 桁（段 1 の線が 2 個目のタブの左端）")
    XCTAssertFalse(try hasInk(ground, col(2), rowMidY(4)))

    try Data("f {\n  a\n    b\n\t\tc\n}\n".utf8).write(to: hosted.document.url)
    hosted.document.reconcileWithDisk()
    XCTAssertEqual(hosted.document.indentUnit, 2)
    waitDrawn { try self.hasInk(ground, col(2), self.rowMidY(3)) }
    XCTAssertFalse(try hasInk(ground, col(4), rowMidY(2)), "単位 2 の 1 段の行に 4 桁目の線は無い")
    XCTAssertFalse(try hasInk(ground, col(8), rowMidY(3)), "2 段の行に 8 桁目の線は無い")
    XCTAssertTrue(try hasInk(ground, col(2), rowMidY(4)), "タブの幅が 2 桁に移る（段 1 の線が 2 個目のタブの左端）")
    XCTAssertFalse(try hasInk(ground, col(8), rowMidY(4)), "タブが 4 桁のままなら立つ 8 桁目の線は無い")
  }

  /// CRLF の文書でも段落末は行の外——行末の 1 個のスペースに点が出て、空行のインデント線が隣から続く
  /// （`"\r\n"` は Character 1 個なので、文字単位で改行を落とすと CR が残って両方消える）。
  func testCRLFParagraphsKeepTrailingSpaceDotsAndBlankLineGuides() throws {
    let hosted = try host("  a \r\n\r\n    b\r\n")
    let ground = hosted.ground
    let guide = bodyX + 2 * cell
    waitDrawn { try self.hasInk(ground, guide, self.rowMidY(3)) }
    XCTAssertFalse(isBlack(try rgb(ground, bodyX + 3.5 * cell, rowMidY(1))), "行末の 1 個に点")
    XCTAssertTrue(try hasInk(ground, guide, rowMidY(2)), "空行に隣の浅い方（1 段）の線")
  }

  /// 丸点は行頭・行末・2 個以上の連続スペースのセルの中央に出て、単語間の 1 個には出ない。
  func testWhitespaceDotsOnlyAtBoundaries() throws {
    let hosted = try host("a b  c \n")
    let ground = hosted.ground
    let center = { (index: Int) in self.bodyX + (CGFloat(index) + 0.5) * self.cell }
    XCTAssertTrue(isBlack(try rgb(ground, center(1), rowMidY(1))), "単語間の 1 個")
    XCTAssertFalse(isBlack(try rgb(ground, center(3), rowMidY(1))), "2 個以上の連続")
    XCTAssertFalse(isBlack(try rgb(ground, center(4), rowMidY(1))))
    XCTAssertFalse(isBlack(try rgb(ground, center(6), rowMidY(1))), "行末")
  }

  /// URL の下に、文字と同じ色（コメントの中なら comment の色）の 1px の線が行の下部に連続して出る（字の
  /// 隙間でも切れない）。
  func testLinkUnderlineRunsBelowTheURLInTheTextsColor() throws {
    let hosted = try host("// see https://a.b/c now\n")
    let ground = hosted.ground
    let x0 = bodyX + 7 * cell
    let x1 = bodyX + 20 * cell
    let comment = try onBlack(try XCTUnwrap(style.roleColors[.comment]))
    XCTAssertFalse(matches(comment, try onBlack(style.textColor)), "前提: comment の色は素の文字色と違う")
    func underlineY() throws -> CGFloat? {
      for y in stride(from: style.topInset + 10, to: style.topInset + style.lineHeight, by: 1) {
        let xs = stride(from: x0 + 0.5, to: x1, by: cell / 2)
        if try xs.allSatisfy({ !isBlack(try rgb(ground, $0, y)) }) { return y }
      }
      return nil
    }
    waitDrawn {
      guard let y = try underlineY() else { return false }
      return self.matches(try self.rgb(ground, x0 + self.cell, y), comment)
    }
    let y = try XCTUnwrap(try underlineY(), "URL の幅いっぱいの連続した線")
    XCTAssertTrue(matches(try rgb(ground, x0 + 9 * cell, y), comment), "線は端から端まで文字と同色")
    XCTAssertTrue(isBlack(try rgb(ground, x0 - cell / 2, y)), "URL の前には無い")
    XCTAssertTrue(isBlack(try rgb(ground, x1 + cell / 2, y)), "URL の後には無い")
  }

}
