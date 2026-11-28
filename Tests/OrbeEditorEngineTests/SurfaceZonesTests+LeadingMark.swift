import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import OrbeEditorEngine

/// 行の頭の印——印の組を持つ行の頭の列に線をいつも描き、ポインタが乗った行に絵を出し、絵を押して離すと押した行を、引いて
/// 離すと同じ組の範囲を、並びの順で最初と最後の行にして 1 回だけ並びの受け手へ知らせる。壊れると、コメントできない行に
/// 入口が出る・別の行の欄が開く・ハンクをまたぐ範囲ができる・並びを置き直した後に古い受け手へ届く。
extension SurfaceZonesTests {
  /// 知らせを残す受け手。
  final class MarkRecorder: SurfaceLeadingMarkTarget {
    var lines: [(LeadingMarkLine, LeadingMarkLine)] = []

    func surface(
      _ surface: any TextSurface, didMarkFrom first: LeadingMarkLine, to last: LeadingMarkLine
    ) {
      lines.append((first, last))
    }
  }

  /// 塗りつぶした 16×16 の絵。
  static let markImage = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
    NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).setFill()
    rect.fill()
    return true
  }

  static let mark = LeadingMark(
    width: 24, lineWidth: 3, lineColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
    size: CGSize(width: 16, height: 16), image: markImage, dragOverride: 0)

  /// 引いている範囲の上書き（地は青・線は白）。
  static let presentation = SurfacePresentation(
    showsMinimap: false,
    lineOverrides: [
      LineOverride(
        background: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
        markColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ], leadingMark: mark)

  /// 行 3〜7 が組 0（行 5 の前に、組 0 の削除行 2 つと組を持たない詰め物 1 つ、行 6 の前にスレッド）、行 8 が組を持たず、
  /// 行 9〜11 が組 1、行 12 から先は組を持たない面。
  struct Marked {
    let opened: Opened
    let target: MarkRecorder
    let thread: ThreadZone
  }

  func marked() throws -> Marked {
    let opened = try hostedRows()
    let surface = opened.surface
    surface.setPresentation(Self.presentation)
    let source = InsertedText()
    var inserted = source.lines(["- a", "- b"])
    inserted[0].markGroup = 0
    inserted[1].markGroup = 0
    let target = MarkRecorder()
    let thread = ThreadZone(comment: "本文")
    surface.setRows(
      SurfaceRows(
        insertions: [
          RowInsertion(line: 5, content: .lines(inserted + [InsertedLine(markGroup: 0)])),
          RowInsertion(line: 6, content: .zone(thread)),
        ],
        spans: [
          LineSpan(line: 0), LineSpan(line: 3, markGroup: 0), LineSpan(line: 8),
          LineSpan(line: 9, markGroup: 1), LineSpan(line: 12),
        ], source: source, leadingMarkTarget: target))
    return Marked(opened: opened, target: target, thread: thread)
  }

  /// 文書の行 `row` の中ほどの点（`x` は view の座標）。
  func rowPoint(_ surface: MetalTextSurface, row: Int, x: CGFloat = 200) -> CGPoint {
    CGPoint(
      x: x,
      y: surface.config.topInset + CGFloat(surface.rows.y(ofLine: row) - surface.scrollPosition.y)
        + surface.config.lineHeight / 2)
  }

  /// 塊 0 の中の `line` 行目の中ほどの点。
  func insertedPoint(_ surface: MetalTextSurface, line: Int, x: CGFloat = 200) -> CGPoint {
    CGPoint(
      x: x,
      y: surface.config.topInset
        + CGFloat(surface.rows.top(ofBlock: 0) - surface.scrollPosition.y)
        + (CGFloat(line) + 0.5) * surface.config.lineHeight)
  }

  /// 印を出せる行に乗った間だけ、その行（文書の行か、差し込んだ行）に絵が出る。組を持たない行・何も指さない差し込んだ
  /// 行・絵の差し込みの上では出ない。頭の列・行番号・本文のどこに乗っても同じ行。行から行へ動かしても、絵の差し込みは
  /// 描き直さない。
  func testTheMarkShowsOnlyOnMarkableRowsUnderThePointer() throws {
    let setup = try marked()
    let surface = setup.opened.surface
    let asked = setup.thread.widths.count
    surface.hover(at: rowPoint(surface, row: 4))
    XCTAssertEqual(surface.drawn.leadingMark?.hover, .document(4))
    surface.hover(at: rowPoint(surface, row: 4, x: 4))
    XCTAssertEqual(surface.drawn.leadingMark?.hover, .document(4), "頭の列の上")
    surface.hover(at: rowPoint(surface, row: 2))
    XCTAssertNil(surface.drawn.leadingMark?.hover, "組を持たない行")
    surface.hover(at: insertedPoint(surface, line: 1))
    XCTAssertEqual(surface.drawn.leadingMark?.hover, .inserted(block: 0, line: 1))
    surface.hover(at: insertedPoint(surface, line: 2))
    XCTAssertNil(surface.drawn.leadingMark?.hover, "何も指さない差し込んだ行")
    surface.hover(at: nil)
    XCTAssertNil(surface.drawn.leadingMark, "面の外")
    XCTAssertEqual(setup.thread.widths.count, asked, "絵の差し込みを描き直さない")
  }

  /// 頭の列は行番号の列の左端にあり、印を出せる行には線がいつも描かれ、組を持たない行には描かれない。ポインタの下の行には
  /// 絵が頭の列の左右の中央に出る。
  func testTheLineIsDrawnOnMarkableRowsAndTheImageOnTheHoveredRow() throws {
    let setup = try marked()
    let surface = setup.opened.surface
    XCTAssertEqual(surface.surfaceLayout.gutter.lead, 24)
    var shot = try pixelShot(setup.opened)
    XCTAssertEqual(shot.rgb(1, rowPoint(surface, row: 4).y), [255, 0, 0], "印を出せる行の線")
    XCTAssertEqual(shot.rgb(1, insertedPoint(surface, line: 0).y), [255, 0, 0], "差し込んだ行の線")
    XCTAssertNotEqual(shot.rgb(1, rowPoint(surface, row: 2).y), [255, 0, 0], "組を持たない行")
    XCTAssertNotEqual(shot.rgb(12, rowPoint(surface, row: 4).y), [0, 255, 0], "前提: 絵はまだ無い")
    surface.hover(at: rowPoint(surface, row: 4))
    shot = try pixelShot(setup.opened)
    XCTAssertEqual(shot.rgb(12, rowPoint(surface, row: 4).y), [0, 255, 0], "頭の列の中央の絵")
  }

  /// 頭の列の印を押して離すと、押した行だけを 1 回知らせ、選択と主は変えない。差し込んだ行は出どころの行。並びを置き直した
  /// 後は、置き直した並びの受け手だけが受ける。頭の列の、組を持たない行の所は印に当たらない。
  func testPressingTheMarkTellsTheTargetOfTheCurrentRows() throws {
    let setup = try marked()
    let (opened, target) = (setup.opened, setup.target)
    let surface = opened.surface
    surface.selectedRange = NSRange(location: 2, length: 0)
    let mark = rowPoint(surface, row: 3, x: 12)
    try mouse(opened, .leftMouseDown, at: mark)
    try mouse(opened, .leftMouseUp, at: mark)
    XCTAssertEqual(target.lines.map(\.0), [.document(3)])
    XCTAssertEqual(target.lines.map(\.1), [.document(3)])
    XCTAssertEqual(surface.selectedRange, NSRange(location: 2, length: 0), "選択は変えない")
    let source = insertedPoint(surface, line: 1, x: 12)
    try mouse(opened, .leftMouseDown, at: source)
    try mouse(opened, .leftMouseUp, at: source)
    XCTAssertEqual(target.lines.last?.0, .source(1), "差し込んだ行は出どころの行")
    if case .leadingMark = surface.target(at: rowPoint(surface, row: 2, x: 12)) {
      XCTFail("組を持たない行の頭の列は印に当たらない")
    }
    let next = MarkRecorder()
    surface.setRows(
      SurfaceRows(spans: [LineSpan(line: 0, markGroup: 0)], leadingMarkTarget: next))
    try mouse(opened, .leftMouseDown, at: mark)
    try mouse(opened, .leftMouseUp, at: mark)
    XCTAssertEqual(target.lines.count, 2, "古い並びの受け手へは届かない")
    XCTAssertEqual(next.lines.map(\.0), [.document(3)])
  }

  /// 引くと、押した行から、ポインタの下の同じ組の行までが範囲になり、離すと並びの順で最初と最後の行を知らせる。組を持たない
  /// 行と絵の差し込みは飛び越し、別の組の行の手前で止まる。上へ引いても、知らせは並びの順。
  func testDraggingTheMarkMakesARangeInTheSameGroup() throws {
    let setup = try marked()
    let (opened, target) = (setup.opened, setup.target)
    let surface = opened.surface
    try mouse(opened, .leftMouseDown, at: rowPoint(surface, row: 4, x: 12))
    try mouse(opened, .leftMouseDragged, at: insertedPoint(surface, line: 2))
    XCTAssertEqual(
      surface.drawn.leadingMark?.range?.last, .inserted(block: 0, line: 1),
      "詰め物の上では、その手前の同じ組の行まで")
    XCTAssertNil(surface.drawn.leadingMark?.hover, "引いている間は絵を出さない")
    try mouse(opened, .leftMouseDragged, at: rowPoint(surface, row: 10))
    XCTAssertEqual(
      surface.drawn.leadingMark?.range?.last, .document(7), "別の組の行の手前で止まる")
    try mouse(opened, .leftMouseUp, at: rowPoint(surface, row: 10))
    XCTAssertEqual(target.lines.count, 1)
    XCTAssertEqual(target.lines.last?.0, .document(4))
    XCTAssertEqual(target.lines.last?.1, .document(7))
    XCTAssertNil(surface.drawn.leadingMark?.range, "離せば範囲を下ろす")

    try mouse(opened, .leftMouseDown, at: rowPoint(surface, row: 7, x: 12))
    try mouse(opened, .leftMouseDragged, at: rowPoint(surface, row: 1))
    try mouse(opened, .leftMouseUp, at: rowPoint(surface, row: 1))
    XCTAssertEqual(target.lines.last?.0, .document(3), "上へ引いても、最初の行は並びの順で前の行")
    XCTAssertEqual(target.lines.last?.1, .document(7))
  }

  /// 引いている間に並びを置き直すと、引く操作を終え、離すまでは ＋ も出さず、離しても知らせない。離した後は ＋ が出る。
  func testNewRowsWhileDraggingEndTheDrag() throws {
    let setup = try marked()
    let (opened, target) = (setup.opened, setup.target)
    let surface = opened.surface
    try mouse(opened, .leftMouseDown, at: rowPoint(surface, row: 4, x: 12))
    try mouse(opened, .leftMouseDragged, at: rowPoint(surface, row: 6))
    surface.setRows(
      SurfaceRows(spans: [LineSpan(line: 0, markGroup: 0)], leadingMarkTarget: target))
    XCTAssertNil(surface.drawn.leadingMark?.range)
    surface.hover(at: rowPoint(surface, row: 6))
    XCTAssertNil(surface.drawn.leadingMark?.hover, "押している間は ＋ を出さない")
    try mouse(opened, .leftMouseUp, at: rowPoint(surface, row: 6))
    XCTAssertTrue(target.lines.isEmpty)
    surface.hover(at: rowPoint(surface, row: 6))
    XCTAssertEqual(surface.drawn.leadingMark?.hover, .document(6), "離した後は ＋ が出る")
  }

  /// スクロールの後と並びを置き直した後は、今のポインタの位置で絵を引き直す——ポインタの下へ来た行に移り、置き直した並びで
  /// 出せなくなった行からは消える。
  func testTheMarkIsPickedAgainUnderThePointerAfterScrollingAndNewRows() throws {
    let opened = try open(rows(80), size: CGSize(width: 600, height: 400))
    let surface = opened.surface
    let window = PointerWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.answersAsKey = true
    window.contentView = surface.view
    surface.viewStateDidChange(size: CGSize(width: 600, height: 400), scale: 2, visible: false)
    addTeardownBlock { @MainActor in window.contentView = nil }
    surface.setPresentation(Self.presentation)
    let markable = [LineSpan(line: 0, markGroup: 0)]
    surface.setRows(SurfaceRows(spans: markable))
    window.pointer = surface.textView.convert(rowPoint(surface, row: 4), to: nil)
    surface.refreshPointer()
    XCTAssertEqual(surface.drawn.leadingMark?.hover, .document(4), "前提: ポインタの下の行に絵が出る")
    surface.scroll(to: RowPosition(line: 2))
    XCTAssertEqual(surface.drawn.leadingMark?.hover, .document(6), "スクロールの後はポインタの下へ来た行に移る")
    surface.setRows(SurfaceRows(spans: markable + [LineSpan(line: 5)]))
    XCTAssertNil(surface.drawn.leadingMark?.hover, "置き直した並びで出せなくなった行からは消える")
  }
}
