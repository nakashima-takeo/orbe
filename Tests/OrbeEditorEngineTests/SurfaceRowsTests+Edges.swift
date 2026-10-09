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
    surface.setRows(placed([insert((0..<50).map { "inserted \($0)" }, at: 10)]))
    let text = opened.document.text
    surface.selectedRange = NSRange(location: text.lineStart(10), length: 0)
    let pageLines = try XCTUnwrap(surface.bodySite.editingEnvironment()).pageLines
    XCTAssertLessThan(pageLines, 50, "前提: 差し込みはページより高い")
    surface.editor.perform(.move(.pageUp, extending: false))
    XCTAssertEqual(text.row(containing: surface.caretLocation), 9, "差し込みの上の文書の行")
  }

  /// 文書の先頭（位置 0）で境 0 に塊を置いても伸ばしても、位置 0 のまま（塊が画面の上に隠れない）。
  func testABlockAtTheTopOfTheDocumentStaysInViewAtPositionZero() throws {
    let opened = try openRows()
    let surface = opened.surface
    surface.flush()
    XCTAssertEqual(surface.scrollPosition.y, 0, "前提: 先頭")
    surface.setRows(placed([insert(["a", "b", "c"], at: 0)]))
    surface.flush()
    XCTAssertEqual(surface.scrollPosition.y, 0)
    surface.setRows(placed([insert(["a", "b", "c", "d", "e"], at: 0)]))
    surface.flush()
    XCTAssertEqual(surface.scrollPosition.y, 0, "伸ばしても")
  }

  /// 見せた直後に、同じ回で上へ差し込みを置いても、見せた行は見せた位置に残る（まだ出していない置く位置をずらす）。
  func testRowsPlacedRightAfterARevealKeepTheRevealedLine() throws {
    let opened = try openRows()
    let surface = opened.surface
    surface.flush()
    let text = opened.document.text
    surface.reveal(NSRange(location: text.lineStart(40), length: 0), policy: .center)
    let centered = surface.rows.y(ofLine: 40) - surface.scrollPosition.y
    surface.setRows(placed([insert(["a", "b", "c"], at: 10)]))
    surface.flush()
    XCTAssertEqual(
      surface.rows.y(ofLine: 40) - surface.scrollPosition.y, centered, accuracy: 1e-9,
      "行 40 は見せた位置のまま")
  }

  /// 変更行が差し込みをまたぐと、git の印のバーは差し込みの境で切れ、差し込んだ行の印の列には描かれない。
  func testTheGitBarBreaksAtTheBlockItSpans() throws {
    let opened = try openRows(20)
    var baseline = text(opened.document).components(separatedBy: "\n")
    for row in [2, 3] { baseline[row] = "old \(row)" }
    opened.document.baseline = baseline.joined(separator: "\n")
    XCTAssertTrue(opened.document.waitUntilCaughtUp())
    opened.surface.setRows(placed([insert(["- one", "- two"], at: 3)]))
    let shot = try pixelShot(opened)
    let config = opened.surface.config
    let column = config.columnWidth(lineCount: opened.document.text.lineCount)
    let marks = stride(from: column - config.marks.gutterWidth, to: column, by: 0.5)
    let inked = { (y: CGFloat) in marks.contains { shot.hasInk($0, config.topInset + y) } }
    XCTAssertTrue(inked(2.5 * config.lineHeight), "行 2 の印")
    XCTAssertFalse(inked(3.5 * config.lineHeight), "差し込んだ行には印が無い")
    XCTAssertFalse(inked(4.5 * config.lineHeight))
    XCTAssertTrue(inked(5.5 * config.lineHeight), "差し込みの下へ下がった行 3 の印")
  }

  /// 差し込みの下の行で変換すると、未確定の矩形と点の下の字は差し込みの高さを数えた行の位置で答える（候補窓が描いた行に
  /// 出る）。
  func testInputMethodGeometryBelowABlockCountsTheBlock() throws {
    let opened = try openRows(20)
    let window = host(opened, size: size)
    fakeInputMethod(opened)
    let surface = opened.surface
    let view = surface.textView
    surface.setRows(placed([insert(["a", "b", "c"], at: 3)]))
    let text = opened.document.text
    surface.selectedRange = NSRange(location: text.lineStart(5), length: 0)
    replay([.mark("か")], on: opened)
    let config = surface.config
    let rect = view.convert(
      window.convertFromScreen(
        view.firstRect(forCharacterRange: view.markedRange(), actualRange: nil)), from: nil)
    XCTAssertEqual(rect.minY, config.topInset + CGFloat(surface.rows.y(ofLine: 5)), accuracy: 0.5)
    let below = CGPoint(
      x: config.columnWidth(lineCount: text.lineCount) + 2.3 * config.cell,
      y: config.topInset + CGFloat(surface.rows.y(ofLine: 7)) + config.lineHeight / 2)
    XCTAssertEqual(
      view.characterIndex(for: window.convertPoint(toScreen: view.convert(below, to: nil))),
      opened.document.text.lineStart(7) + 2, "未確定を含む今の本文の位置")
  }
}
