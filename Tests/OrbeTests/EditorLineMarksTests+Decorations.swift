import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 本文の装備——外部変更の差し替えで決め直すタブ幅。
extension EditorLineMarksTests {

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

}
