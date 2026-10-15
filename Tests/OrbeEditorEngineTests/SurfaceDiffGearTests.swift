import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// diff の装備——番号の列（2 列ならもう一方の番号）・記号の列・印の列の有無と番号の列の寸法で決まる行番号の列の配置、行の型の
/// 地と記号、差し込んだ行の字（出どころの行・出どころの役割の色・空白の点・番号）、区間の始まりの追従。壊れると、旧番号が
/// 編集でずれる・行の地が行番号の列やスクロールバーの下に掛からない・削除行が素の字で出る・裏から届いた色が削除行に出ない・
/// 差し込んだ削除行の番号を押して隣の行が選ばれる。
@MainActor
final class SurfaceDiffGearTests: EngineTestCase {
  private let size = CGSize(width: 600, height: 300)
  private let red = NSColor(srgbRed: 0.5, green: 0, blue: 0, alpha: 1)
  private let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

  /// インラインの diff の構成——番号 2 列・記号の列 18・印の列なし・型 0（地・記号）。
  private var inline: SurfacePresentation {
    SurfacePresentation(
      showsMinimap: false, numberColumns: 2, signWidth: 18, showsMarks: false,
      lineStyles: [LineStyle(background: red, sign: "+", signColor: blue)])
  }

  /// 字の色が鍵語（`EngineTestCase.style` の keyword）か。
  private let isKeyword = { (rgb: [Int]) in rgb[2] > 180 && rgb[0] < 120 && rgb[1] > 120 }

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

  /// 構成が番号の列の最小の幅と右の余白を持てば、見え方の値に代わってそれで列を組む。
  func testThePresentationSetsTheNumberColumnSize() throws {
    let opened = try open(rows(20), size: size)
    let surface = opened.surface
    var presentation = inline
    presentation.numberWidth = 30
    presentation.numberTrailing = 4
    surface.setPresentation(presentation)
    surface.setRows(SurfaceRows(spans: [LineSpan(line: 0, otherNumber: 1)]))
    let config = surface.config
    let own = max(30, ceil(config.numberWidth(21)) + 4)
    XCTAssertEqual(surface.surfaceLayout.gutter.own, own)
    XCTAssertEqual(surface.surfaceLayout.gutter.trailing, 4)
    XCTAssertEqual(surface.surfaceLayout.column, own * 2 + 18)
  }

  /// 行の型の地は行番号の列の左端から面の右端（縦スクロールバーの列の下）まで塗られ、記号は記号の列に描かれ、字は型に依らず
  /// 構文の色。差し込んだ行は出どころの行の字を出どころの役割の色で描き、2 列の面の左の列に出どころの行の番号が出る。何も
  /// 指さない差し込んだ行（詰め物）は地と記号だけ。型の無い行に地と記号は無い。
  func testLineStylesPaintTheWholeRowAndInsertedLinesDrawTheSource() throws {
    let lines = (0..<20).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"
    let opened = try open(lines, size: size)
    let surface = opened.surface
    surface.setPresentation(inline)
    let source = InsertedText()
    let removed = source.lines(["first", "let gone = 1"], style: 0)
    _ = source.setRole(.keyword, line: 1)
    surface.setRows(
      SurfaceRows(
        insertions: [RowInsertion(line: 4, content: .lines([removed[1], InsertedLine(style: 0)]))],
        spans: [LineSpan(line: 0, otherNumber: 1), LineSpan(line: 2, style: 0), LineSpan(line: 3)],
        source: source))
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
    for row in [2.0, 4.0, 5.0] {
      XCTAssertTrue(isRed(shot.rgb(0.5, middle(row))), "表示の行 \(row) の地は列の左端から")
      XCTAssertTrue(isRed(shot.rgb(size.width - 1, middle(row))), "面の右端（スクロールバーの列の下）まで")
      XCTAssertTrue(inked(sign, middle(row)) { $0[2] > 150 }, "記号の列に記号")
    }
    XCTAssertTrue(inked(text, middle(2), isKeyword), "型のある文書の行の字は構文の色")
    XCTAssertTrue(inked(text, middle(4), isKeyword), "差し込んだ行は出どころの行の字を出どころの役割の色で")
    XCTAssertFalse(inked(text, middle(5)) { $0[1] > 60 }, "詰め物に字は無い")
    for row in [1.0, 6.0] {
      XCTAssertFalse(isRed(shot.rgb(0.5, middle(row))), "型の無い行に地は無い")
      XCTAssertTrue(inked(text, middle(row), isKeyword), "型の無い行も構文の色")
      XCTAssertFalse(inked(sign, middle(row)) { $0[2] > 150 }, "型の無い行に記号は無い")
    }
    let split = layout.gutter.other ?? 0
    let number = { (rgb: [Int]) in rgb[1] > 60 }
    let gutter = split...(layout.column - 18)
    XCTAssertTrue(inked(0...split, middle(4), number), "差し込んだ行の左の列に出どころの行の番号")
    XCTAssertFalse(inked(gutter, middle(4), number), "差し込んだ行の右の列は空")
    XCTAssertFalse(inked(0...layout.column - 18, middle(5), number), "詰め物に番号は無い")
    XCTAssertTrue(inked(gutter, middle(6), number), "文書の行の右の列に行の番号")
    XCTAssertTrue(inked(0...split, middle(0), number), "区間のもう一方の番号")
    XCTAssertFalse(inked(0...split, middle(3), number), "もう一方の番号の無い区間は空")
    XCTAssertEqual(layout.gutter.other, max(config.gutterWidth, ceil(config.numberWidth(21)) + 16))
  }

  /// 差し込んだ行の空白にも、文書の行と同じ規則で点が出る。
  func testInsertedLinesShowWhitespaceDots() throws {
    let opened = try open(rows(20), size: size)
    let surface = opened.surface
    surface.setPresentation(inline)
    let source = InsertedText()
    let lines = source.lines(["a    b"])
    surface.setRows(
      SurfaceRows(insertions: [RowInsertion(line: 2, content: .lines(lines))], source: source))
    let shot = try pixelShot(opened)
    let config = surface.config
    let left = surface.surfaceLayout.text.minX
    let y = config.topInset + 2.5 * config.lineHeight
    let isDot = { (rgb: [Int]) in rgb.allSatisfy { (96...160).contains($0) } }
    XCTAssertTrue(
      stride(from: left + config.cell, to: left + config.cell * 5, by: 0.5).contains {
        isDot(shot.rgb($0, y))
      }, "差し込んだ行の空白の点")
  }

  /// 出どころの役割が変わったと知らせると、差し込んだ行が新しい役割の色で描き直される（知らせるまでは前の色のまま）。
  func testSourceRolesRedrawTheInsertedLines() throws {
    let opened = try open(rows(20), size: size)
    let surface = opened.surface
    surface.setPresentation(inline)
    let source = InsertedText()
    let lines = source.lines(["let gone = 1"])
    surface.setRows(
      SurfaceRows(insertions: [RowInsertion(line: 2, content: .lines(lines))], source: source))
    let config = surface.config
    let layout = surface.surfaceLayout
    let y = config.topInset + 2.5 * config.lineHeight
    func keyword(_ shot: PixelShot) -> Bool {
      stride(from: layout.text.minX + 1, to: layout.text.minX + 60, by: 0.5).contains {
        isKeyword(shot.rgb($0, y))
      }
    }
    XCTAssertFalse(keyword(try pixelShot(opened)), "前提: 役割の無い字は本文の色")
    let changed = source.setRole(.keyword, line: 0)
    XCTAssertFalse(keyword(try pixelShot(opened)), "知らせるまでは引いた写しの色")
    surface.rowSourceRolesDidChange(changed)
    XCTAssertTrue(keyword(try pixelShot(opened)), "知らせを受けて出どころの写しを引き直す")
  }

  /// 差し込みの形が同じでも出どころを替えて置き直せば、差し込んだ行は新しい出どころの字と色で描かれる（版が変わって削除行の
  /// 数が同じでも、古い版の字が残らない）。
  func testReplacingTheSourceRedrawsTheInsertedLines() throws {
    let opened = try open(rows(20), size: size)
    let surface = opened.surface
    surface.setPresentation(inline)
    let colored = InsertedText()
    let lines = colored.lines(["let gone = 1"])
    _ = colored.setRole(.keyword, line: 0)
    let plain = InsertedText()
    _ = plain.lines(["let gone = 1"])
    let insertions = [RowInsertion(line: 2, content: .lines(lines))]
    surface.setRows(SurfaceRows(insertions: insertions, source: colored))
    let config = surface.config
    let layout = surface.surfaceLayout
    let y = config.topInset + 2.5 * config.lineHeight
    func keyword(_ shot: PixelShot) -> Bool {
      stride(from: layout.text.minX + 1, to: layout.text.minX + 60, by: 0.5).contains {
        isKeyword(shot.rgb($0, y))
      }
    }
    XCTAssertTrue(keyword(try pixelShot(opened)), "前提: 前の出どころの役割の色")
    surface.setRows(SurfaceRows(insertions: insertions, source: plain))
    XCTAssertFalse(keyword(try pixelShot(opened)), "新しい出どころの写しで描く")
  }

  /// 差し込んだ行の番号を押しても行は選ばれない（行番号の列での行の選択は文書の行だけ）。
  func testClickingTheNumbersOfAnInsertedLineSelectsNothing() throws {
    let opened = try hosted(rows(20), size: size)
    let surface = opened.surface
    surface.setPresentation(inline)
    let source = InsertedText()
    surface.setRows(
      SurfaceRows(
        insertions: [
          RowInsertion(line: 3, content: .lines(source.lines(["gone"])))
        ], source: source))
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
