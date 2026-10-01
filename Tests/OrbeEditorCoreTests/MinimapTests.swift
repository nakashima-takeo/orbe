import CoreText
import Foundation
import XCTest

@testable import OrbeEditorCore

/// ミニマップの規則——行を字の列にする（`MinimapLine`）と、配置（`MinimapLayout`）。正解は VS Code（f83f3fba）の
/// `MinimapLayout.create` / `_renderLine` / `getXOffsetForPosition` を行高 18・余白 0・scrollBeyondLastLine で実行した値。
/// 壊れると帯が本文の位置とずれる、長い文書の末尾がミニマップに出ない、字の桁がずれて形が崩れる、帯のドラッグで本文が
/// 指と違う量だけ動く。
final class MinimapTests: XCTestCase {
  private func units(_ text: String) -> [UInt16] { Array(text.utf16) }

  /// 行の字を桁・字形・行の中の位置の列で集める。
  private func cells(_ text: String, columns: Int = 100) -> [(column: Int, glyph: Int, index: Int)]
  {
    var result: [(column: Int, glyph: Int, index: Int)] = []
    MinimapLine.forEachCell(units(text), tabSize: 4, columns: columns) {
      result.append(($0, $1, $2))
    }
    return result
  }

  func testCellsSkipBlanksExpandTabsToTheNextStopAndDoubleFullWidth() {
    let plain = cells("a b\tc")
    XCTAssertEqual(plain.map(\.column), [0, 2, 4], "空白は描かず 1 桁、タブは次のタブ位置まで")
    XCTAssertEqual(plain.map(\.glyph), [65, 66, 67])
    XCTAssertEqual(plain.map(\.index), [0, 2, 4], "行の中の UTF-16 位置")
    let wide = cells("あx")
    XCTAssertEqual(wide.map(\.column), [0, 1, 2], "全角は 2 セル")
    XCTAssertEqual(wide[0].glyph, wide[1].glyph)
    XCTAssertEqual(
      cells("あ\tx").last?.column, 5, "タブの送りは UTF-16 の位置で数える（VS Code と同じく全角は数え直さない）")
  }

  func testCellsStopAtTheDrawableColumns() {
    XCTAssertEqual(cells("let x = 1", columns: 5).map(\.column), [0, 1, 2, 4])
    XCTAssertEqual(cells("abあ", columns: 3).map(\.column), [0, 1, 2], "全角の 2 桁目は描ける桁で切れる")
    XCTAssertEqual(MinimapLine.columns(canvasWidth: 120, scale: 1), 112, "幅 120pt・1x")
    XCTAssertEqual(MinimapLine.columns(canvasWidth: 240, scale: 2), 116, "幅 120pt・2x")
  }

  func testGlyphIndexIsAsciiMinus32AndOtherCharactersWrapIntoAscii() {
    XCTAssertEqual(MinimapLine.glyph(of: 0x21), 1)
    XCTAssertEqual(MinimapLine.glyph(of: 0x7E), 94)
    XCTAssertEqual(MinimapLine.glyph(of: 0x3042), (0x3042 - 32 + 96) % 96)
    XCTAssertTrue((0..<96).contains(MinimapLine.glyph(of: 0x05)))
  }

  /// 字形の表は 1 字 `scale` × `2·scale` デバイス px の明度で、空白は空、最も明るい値は 255 近くに揃う。描画スレッドも読むので、
  /// 同じフォント・倍率なら何度作っても同じ値。
  func testCharSheetIsNormalizedAndDeterministic() {
    let font = CTFontCreateUIFontForLanguage(.userFixedPitch, 12, nil)!
    for scale in [1, 2] {
      let sheet = MinimapCharSheet(scale: scale, font: font)
      XCTAssertEqual(sheet.data.count, MinimapLine.glyphCount * scale * scale * 2)
      XCTAssertTrue(
        (0..<scale * 2).allSatisfy { y in
          (0..<scale).allSatisfy { sheet.value(0, x: $0, y: y) == 0 }
        }, "空白")
      XCTAssertGreaterThanOrEqual(sheet.data.max() ?? 0, 254, "最も明るい字は 255 近く")
      XCTAssertEqual(MinimapCharSheet(scale: scale, font: font).data, sheet.data)
    }
  }

  /// 装飾の x はタブを固定の `tabSize` 桁と数え（字の置き方と違う）、全角は 2 桁。
  func testDecorationWidthsCountTabsAsTheFixedTabSize() {
    XCTAssertEqual(
      units("a\tあ").map { MinimapLine.decorationWidth(of: $0, tabSize: 4) }, [1, 4, 2])
  }

  func testWidthFollowsTheTextWidthUpToTheMaximum() {
    XCTAssertEqual(
      MinimapLayout.width(remaining: 631, charWidth: 7, scrollbar: 14, maxWidth: 120), 84)
    XCTAssertEqual(
      MinimapLayout.width(remaining: 1500, charWidth: 7, scrollbar: 14, maxWidth: 120), 120)
    XCTAssertEqual(MinimapLayout.width(remaining: 0, charWidth: 7, scrollbar: 14, maxWidth: 120), 8)
  }

  /// 文書がミニマップに収まるとき: 行 0 から描き、帯はスクロール比で動く（最終行を最上段へ送ると帯は下端へ）。
  func testLayoutOfADocumentThatFits() {
    let top = MinimapLayout(lineCount: 60, firstLine: 0, visibleLines: 20, height: 400)
    XCTAssertTrue(top.sliderNeeded)
    XCTAssertEqual(top.lines, 0..<60)
    XCTAssertEqual(top.sliderTop, 0)
    XCTAssertEqual(top.sliderHeight, 40)
    let mid = MinimapLayout(lineCount: 60, firstLine: 10.5, visibleLines: 20, height: 400)
    XCTAssertEqual(mid.sliderTop, 20.64406779661017, accuracy: 1e-9)
    let end = MinimapLayout(lineCount: 60, firstLine: 59, visibleLines: 20, height: 400)
    XCTAssertEqual(end.sliderTop, 116, accuracy: 1e-9)
    XCTAssertEqual(1 / top.linesPerSliderPoint, 1.9661016949152543, accuracy: 1e-9)
    let short = MinimapLayout(lineCount: 5, firstLine: 0, visibleLines: 20, height: 400)
    XCTAssertTrue(short.sliderNeeded, "1 画面より短くても最終行を最上段まで送れる")
    XCTAssertEqual(1 / short.linesPerSliderPoint, 1.5, accuracy: 1e-9)
    XCTAssertFalse(
      MinimapLayout(lineCount: 1, firstLine: 0, visibleLines: 20, height: 400).sliderNeeded)
  }

  /// 収まらないとき: 描き始めの行がスクロールに合わせてずれ、帯は描いた行に合わせて置かれる。
  func testLayoutOfALongDocumentSlides() {
    let top = MinimapLayout(lineCount: 1000, firstLine: 0, visibleLines: 20, height: 400)
    XCTAssertEqual(top.lines, 0..<200)
    XCTAssertEqual(top.sliderTop, 0)
    let mid = MinimapLayout(lineCount: 1000, firstLine: 400.25, visibleLines: 20, height: 400)
    XCTAssertEqual(mid.lines, 327..<527)
    XCTAssertEqual(mid.sliderTop, 146.5, accuracy: 1e-9)
    XCTAssertEqual(mid.y(ofLine: 400), 146)
    let end = MinimapLayout(lineCount: 1000, firstLine: 999, visibleLines: 20, height: 400)
    XCTAssertEqual(end.lines, 819..<1000)
    XCTAssertEqual(end.sliderTop, 360, accuracy: 1e-9, "最終行が最上段で帯は下端")
    let tall = MinimapLayout(lineCount: 1000, firstLine: 400.25, visibleLines: 20, height: 401)
    XCTAssertEqual(1 / tall.linesPerSliderPoint, 0.3613613613613614, accuracy: 1e-9)
  }

  /// 揺れ止め: 同じスクロール全体のまま下へ送る間は描き始めの行を減らさず、上へ戻す間は増やさない。
  func testLayoutKeepsTheStartLineStableWhileScrollingInOneDirection() {
    var previous: MinimapLayout?
    var seen: [(Int, CGFloat)] = []
    for first: CGFloat in [100.0, 101.0, 101.7, 102.0, 101.4, 101.0, 100.6] {
      let layout = MinimapLayout(
        lineCount: 300, firstLine: first, visibleLines: 20, height: 400, previous: previous)
      seen.append((layout.startLine, layout.sliderTop))
      previous = layout
    }
    XCTAssertEqual(seen.map(\.0), [39, 40, 40, 40, 39, 39, 39])
    let expectedTops: [CGFloat] = [122, 122, 123.4, 124, 124.8, 124, 123.2]
    for (got, want) in zip(seen.map(\.1), expectedTops) {
      XCTAssertEqual(got, want, accuracy: 1e-9)
    }
  }

  func testDraggingTheSliderAndPressingOutsideIt() {
    let mid = MinimapLayout(lineCount: 1000, firstLine: 400.25, visibleLines: 20, height: 400)
    XCTAssertEqual(mid.firstLine(afterDragging: 10), 428, accuracy: 1e-9)
    XCTAssertTrue(mid.sliderContains(y: 150))
    XCTAssertFalse(mid.sliderContains(y: 190))
    XCTAssertEqual(mid.line(atY: 11), 332, "押した y の行 = floor(y / 2) + 描き始め")
    XCTAssertEqual(mid.line(atY: 10_000), 999, "行数で止まる")
  }
}
