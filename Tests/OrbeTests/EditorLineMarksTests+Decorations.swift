import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 本文の装備——タブ幅・丸点・URL 下線。
extension EditorLineMarksTests {

  /// タブの表示幅は文書が検出した単位（ここではスペースの行から 2 桁）——2 個のタブの後の字は 4 桁目に立つ（AppKit
  /// 既定の 28pt 刻みのままなら 56pt）。字の有無は字のセルの中央で読む。
  func testTabWidthFollowsTheIndentUnit() throws {
    let hosted = try host("f {\n  a\n\t\tx\n}\n")
    let ground = hosted.ground
    let col = { (n: CGFloat) in self.bodyX + n * self.cell }
    waitDrawn { try self.hasInk(ground, col(4.5), self.rowMidY(3)) }
    XCTAssertEqual(hosted.document.indentation.unit, 2)
    XCTAssertTrue(try hasInk(ground, col(4.5), rowMidY(3)), "2 個のタブの後の字は 4 桁目")
    XCTAssertFalse(try hasInk(ground, bodyX + 56 + cell / 2, rowMidY(3)), "AppKit 既定の刻みには無い")
  }

  /// 外部で書き換えられたファイルの差し替え（本文の丸ごと置き換え）で文書はインデント単位を検出し直して面へ押し、
  /// タブの表示幅がその単位に移る。
  func testReplacingTheWholeTextRedetectsTheIndentUnitAndTabWidth() throws {
    let hosted = try host("f {\n    a\n        b\n\t\tx\n}\n")
    let ground = hosted.ground
    let col = { (n: CGFloat) in self.bodyX + n * self.cell }
    waitDrawn { try self.hasInk(ground, col(8.5), self.rowMidY(4)) }
    XCTAssertEqual(hosted.document.indentation.unit, 4, "前提: 単位 4")
    XCTAssertTrue(try hasInk(ground, col(8.5), rowMidY(4)), "前提: タブの幅も 4 桁（2 個のタブの後の字は 8 桁目）")
    XCTAssertFalse(try hasInk(ground, col(4.5), rowMidY(4)))

    try Data("f {\n  a\n    b\n\t\tx\n}\n".utf8).write(to: hosted.document.url)
    hosted.document.reconcileWithDisk()
    XCTAssertEqual(hosted.document.indentation.unit, 2)
    waitDrawn { try self.hasInk(ground, col(4.5), self.rowMidY(4)) }
    XCTAssertTrue(try hasInk(ground, col(4.5), rowMidY(4)), "タブの幅が 2 桁に移る（字は 4 桁目）")
    XCTAssertFalse(try hasInk(ground, col(8.5), rowMidY(4)), "タブが 4 桁のままなら立つ 8 桁目には無い")
  }

  /// CRLF の文書でも段落末は行の外——行末の 1 個のスペースに点が出る（`"\r\n"` は Character 1 個なので、文字単位で
  /// 改行を落とすと CR が残って点が消える）。
  func testCRLFParagraphsKeepTrailingSpaceDots() throws {
    let hosted = try host("  a \r\n\r\n    b\r\n")
    let ground = hosted.ground
    waitDrawn { !self.isBlack(try self.rgb(ground, self.bodyX + 3.5 * self.cell, self.rowMidY(1))) }
    XCTAssertFalse(isBlack(try rgb(ground, bodyX + 3.5 * cell, rowMidY(1))), "行末の 1 個に点")
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
