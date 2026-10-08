import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 差し込みの端の場合——ページより高い塊をまたぐページ送り・文書の先頭に置く塊・見せた直後に置く並び・塊をまたぐ git の
/// 印。壊れると、高い塊の直下から上へページ送りできない、ファイルを開いた直後に先頭の削除行が画面の上へ隠れる、見せた行が
/// 並びを置いた後にずれる、git の印のバーが差し込んだ行の上まで伸びる。
extension SurfaceRowsTests {
  /// ページより高い差し込みの直下から上へページ送りすると、差し込みを飛び越えて上の文書の行へ動く（差し込みの下の行に
  /// 留まらない）。
  func testPagingUpJumpsOverABlockTallerThanThePage() throws {
    let opened = try openRows()
    let surface = opened.surface
    surface.setRows(SurfaceRows(insertions: [insert((0..<50).map { "inserted \($0)" }, at: 10)]))
    let text = opened.document.text
    surface.selectedRange = NSRange(location: text.lineStart(10), length: 0)
    let pageLines = try XCTUnwrap(surface.bodySite.editingEnvironment()).pageLines
    XCTAssertLessThan(pageLines, 50, "前提: 差し込みはページより高い")
    surface.editor.perform(.move(.pageUp, extending: false))
    XCTAssertEqual(text.row(containing: surface.caretLocation), 9, "差し込みの上の文書の行")
  }
}
