import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// diff の装備——番号の列（2 列ならもう一方の番号）・記号の列・印の列の有無で決まる行番号の列の配置、行の型の地と字の色と
/// 記号、区間の始まりの追従。壊れると、旧番号が編集でずれる・行の地が行番号の列に掛からない・追加行が構文の色で描かれる・
/// 差し込んだ削除行の番号を押して隣の行が選ばれる。
@MainActor
final class SurfaceDiffGearTests: EngineTestCase {
  private let size = CGSize(width: 600, height: 300)
  private let red = NSColor(srgbRed: 0.5, green: 0, blue: 0, alpha: 1)
  private let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
  private let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

  /// インラインの diff の構成——番号 2 列・記号の列 18・印の列なし・型 0（地・字・記号）。
  private var inline: SurfacePresentation {
    SurfacePresentation(
      showsMinimap: false, numberColumns: 2, signWidth: 18, showsMarks: false,
      lineStyles: [LineStyle(background: red, text: green, sign: "+", signColor: blue)])
  }

  /// 番号の列はどれも最小の幅か最大の番号が収まる幅の広い方で、2 列・記号の列が並び、印の列を持たなければその幅は 0。本文の
  /// 区画はその右から始まる。
  func testTheGutterLaysOutTwoNumberColumnsAndTheSignColumn() throws {
    let opened = try open(rows(20), size: size)
    let surface = opened.surface
    let code = surface.surfaceLayout.column
    surface.setPresentation(inline)
    surface.setRows(SurfaceRows(spans: [LineSpan(line: 0, otherNumber: 123_456)]))
    let config = surface.config
    let wide = ceil(config.numberWidth(123_456 + 20)) + config.gutterTrailingInset
    XCTAssertGreaterThan(wide, config.gutterWidth, "前提: もう一方の番号は最小の幅に収まらない")
    let own = max(config.gutterWidth, ceil(config.numberWidth(21)) + config.gutterTrailingInset)
    XCTAssertEqual(surface.surfaceLayout.column, wide + own + 18)
    XCTAssertEqual(surface.surfaceLayout.text.minX, wide + own + 18)
    surface.setPresentation(.code)
    XCTAssertEqual(surface.surfaceLayout.column, code, "コードの構成に戻せる")
  }

  /// 区間の始まりは差し込みの境と同じく上の行に付いて動き、もう一方の番号は区間の始まりの絶対値なので、上に行を足しても
  /// 変わらない。
  func testOtherNumbersStayWhenLinesAreAddedAbove() throws {
    let opened = try open(rows(20), size: size)
    let surface = opened.surface
    surface.setPresentation(inline)
    surface.setRows(
      SurfaceRows(spans: [
        LineSpan(line: 0, otherNumber: 1), LineSpan(line: 5, style: 0, otherNumber: 40),
      ]))
    let text = opened.document.text
    surface.selectedRange = NSRange(location: text.lineStart(2), length: 0)
    surface.textView.insertText("new\n")
    XCTAssertEqual(surface.rows.spans.map(\.line), [0, 6])
    XCTAssertEqual(surface.rows.otherNumber(ofLine: 6), 40, "旧番号は変わらない")
    XCTAssertEqual(surface.rows.style(ofLine: 6), 0)
    XCTAssertNil(surface.rows.style(ofLine: 5))
  }

  /// 行の型の地は行番号の列の左端から本文の区画の右端まで塗られ、字はすべて型の字の色、記号は記号の列に描かれる。差し込んだ
  /// 行にも付き、2 列の面の左の列に渡した番号が出る。型の無い行は構文の色のまま。
  func testLineStylesPaintTheRowTheTextAndTheSign() throws {
    let opened = try open(rows(20), size: size)
    let surface = opened.surface
    surface.setPresentation(inline)
    surface.setRows(
      SurfaceRows(
        insertions: [
          RowInsertion(
            line: 4, content: .lines([InsertedLine("removed line", style: 0, number: 7)]))
        ],
        spans: [LineSpan(line: 0, otherNumber: 1), LineSpan(line: 2, style: 0), LineSpan(line: 3)]))
    let shot = try pixelShot(opened)
    let config = surface.config
    let layout = surface.surfaceLayout
    func middle(_ item: Double) -> CGFloat {
      config.topInset + CGFloat(item + 0.5) * config.lineHeight
    }
    func inked(_ x: ClosedRange<CGFloat>, _ y: CGFloat, _ test: ([Int]) -> Bool) -> Bool {
      stride(from: x.lowerBound, to: x.upperBound, by: 0.5).contains { test(shot.rgb($0, y)) }
    }
    let isRed = { (rgb: [Int]) in abs(rgb[0] - 128) <= 2 && rgb[1] < 4 && rgb[2] < 4 }
    let text = (layout.text.minX + 1)...(layout.text.minX + 60)
    let sign = (layout.column - 18)...layout.column
    for row in [2.0, 4.0] {
      XCTAssertTrue(isRed(shot.rgb(0.5, middle(row))), "表示の行 \(row) の地は列の左端から")
      XCTAssertTrue(isRed(shot.rgb(layout.text.maxX - 1, middle(row))), "本文の区画の右端まで")
      XCTAssertTrue(inked(text, middle(row)) { $0[1] > 150 }, "字は型の色")
      XCTAssertFalse(inked(text, middle(row)) { $0[2] > 60 }, "構文の色を引かない")
      XCTAssertTrue(inked(sign, middle(row)) { $0[2] > 150 }, "記号の列に記号")
    }
    for row in [1.0, 5.0] {
      XCTAssertFalse(isRed(shot.rgb(0.5, middle(row))), "型の無い行に地は無い")
      XCTAssertTrue(inked(text, middle(row)) { $0[2] > 60 }, "型の無い行は構文の色")
      XCTAssertFalse(inked(sign, middle(row)) { $0[2] > 150 }, "型の無い行に記号は無い")
    }
    let split = layout.gutter.other ?? 0
    let number = { (rgb: [Int]) in rgb[1] > 60 }
    XCTAssertTrue(inked(0...split, middle(4), number), "差し込んだ行の左の列に渡した番号")
    XCTAssertFalse(inked(split...(layout.column - 18), middle(4), number), "差し込んだ行の右の列は空")
    XCTAssertTrue(inked(split...(layout.column - 18), middle(5), number), "文書の行の右の列に行の番号")
    XCTAssertTrue(inked(0...split, middle(0), number), "区間のもう一方の番号")
    XCTAssertFalse(inked(0...split, middle(3), number), "もう一方の番号の無い区間は空")
  }

  /// 差し込んだ行の番号を押しても行は選ばれない（行番号の列での行の選択は文書の行だけ）。
  func testClickingTheNumbersOfAnInsertedLineSelectsNothing() throws {
    let opened = try hosted(rows(20), size: size)
    let surface = opened.surface
    surface.setPresentation(inline)
    surface.setRows(
      SurfaceRows(insertions: [
        RowInsertion(line: 3, content: .lines([InsertedLine("gone", number: 3)]))
      ]))
    surface.selectedRange = NSRange(location: 1, length: 0)
    let config = surface.config
    let at = CGPoint(x: 4, y: config.topInset + 3.5 * config.lineHeight)
    try mouse(opened, .leftMouseDown, at: at)
    try mouse(opened, .leftMouseUp, at: at)
    XCTAssertEqual(surface.selectedRange, NSRange(location: 1, length: 0))
    let line = CGPoint(x: 4, y: config.topInset + 4.5 * config.lineHeight)
    try mouse(opened, .leftMouseDown, at: line)
    try mouse(opened, .leftMouseUp, at: line)
    let text = opened.document.text
    XCTAssertEqual(
      surface.selectedRange,
      NSRange(location: text.lineStart(3), length: text.lineStart(4) - text.lineStart(3)),
      "文書の行の番号は行を選ぶ")
  }

  /// 番号の列の数が変わって本文の区画の幅が変われば、区画の絵を新しい幅で問い直す。
  func testChangingTheColumnsAsksZonesAgain() throws {
    let opened = try open(rows(20), size: size)
    let surface = opened.surface
    surface.setPresentation(SurfacePresentation(showsMinimap: false))
    let zone = BoxZone(height: 40)
    surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 3, content: .zone(zone))]))
    surface.setPresentation(inline)
    XCTAssertEqual(zone.widths.last, surface.surfaceLayout.text.width)
    XCTAssertLessThan(zone.widths.last ?? 0, zone.widths.first ?? 0)
  }

  /// 区画の絵の高さが変わって並びを組み直しても、文書の行の区間（行の型・もう一方の番号）と行の地と番号の列の幅は残る。
  func testRegrowingAZoneKeepsTheLineSpans() throws {
    let opened = try open(rows(20), size: size)
    let surface = opened.surface
    surface.setPresentation(inline)
    let zone = BoxZone(height: 40)
    let spans = [LineSpan(line: 0, otherNumber: 123_456), LineSpan(line: 2, style: 0)]
    surface.setRows(
      SurfaceRows(insertions: [RowInsertion(line: 3, content: .zone(zone))], spans: spans))
    let column = surface.surfaceLayout.column
    zone.height = 80
    surface.redrawZone(zone)
    XCTAssertEqual(surface.rows.heights, [80], "前提: 並びが組み直された")
    XCTAssertEqual(surface.rows.spans, spans)
    XCTAssertEqual(surface.surfaceLayout.column, column, "番号の列は縮まない")
    let shot = try pixelShot(opened)
    let rgb = shot.rgb(0.5, surface.config.topInset + 2.5 * surface.config.lineHeight)
    XCTAssertTrue(abs(rgb[0] - 128) <= 2 && rgb[1] < 4 && rgb[2] < 4, "行の地が残る")
  }
}
