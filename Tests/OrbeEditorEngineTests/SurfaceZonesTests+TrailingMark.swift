import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 行の右端の印——印を出せる行にポインタが乗った間だけ、その行の右端に出て、押すと行つきで 1 回だけ並びの受け手へ
/// 知らせる。壊れると、コメントできない行に印が出る・別の行のコメント欄が開く・並びを置き直した後に古い受け手へ届く・
/// ポインタを動かすたびにスレッドを描き直す。
extension SurfaceZonesTests {
  /// 押された行を残す受け手。
  final class MarkRecorder: SurfaceTrailingMarkTarget {
    var pressed: [TrailingMarkLine] = []

    func surface(_ surface: any TextSurface, didPressTrailingMarkOn line: TrailingMarkLine) {
      pressed.append(line)
    }
  }

  /// 塗りつぶした 18×18 の印の絵（外観が暗ければ `dark`、明るければ `light`）。
  static func markImage(dark: NSColor, light: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
      let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      (isDark ? dark : light).setFill()
      rect.fill()
      return true
    }
  }

  static let mark = TrailingMark(
    size: CGSize(width: 18, height: 18), inset: 8,
    image: markImage(
      dark: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
      light: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
    hoveredImage: markImage(
      dark: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
      light: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)))

  /// 行 3〜5 と、行 10 の前に差し込んだ行のうち出どころの行 1 を指す行が印を出せ、行 14 の前にスレッドがある面。
  struct Marked {
    let opened: Opened
    let target: MarkRecorder
    let thread: ThreadZone
  }

  func marked() throws -> Marked {
    let opened = try hostedRows()
    let surface = opened.surface
    surface.setPresentation(SurfacePresentation(showsMinimap: false, trailingMark: Self.mark))
    let source = InsertedText()
    var inserted = source.lines(["- a", "- b"])
    inserted[1].allowsTrailingMark = true
    let target = MarkRecorder()
    let thread = ThreadZone(comment: "本文")
    surface.setRows(
      SurfaceRows(
        insertions: [
          RowInsertion(
            line: 10, content: .lines(inserted + [InsertedLine(allowsTrailingMark: true)])),
          RowInsertion(line: 14, content: .zone(thread)),
        ],
        spans: [
          LineSpan(line: 0), LineSpan(line: 3, allowsTrailingMark: true), LineSpan(line: 6),
        ], source: source, trailingMarkTarget: target))
    return Marked(opened: opened, target: target, thread: thread)
  }

  /// 文書の行 `row` の行の中ほどの点（本文の区画の x）。
  func rowPoint(_ surface: MetalTextSurface, row: Int, x: CGFloat = 40) -> CGPoint {
    CGPoint(
      x: surface.surfaceLayout.text.minX + x,
      y: surface.config.topInset + CGFloat(surface.rows.y(ofLine: row) - surface.scrollPosition.y)
        + surface.config.lineHeight / 2)
  }

  /// 塊 0 の中の `line` 行目の中ほどの点。
  func insertedPoint(_ surface: MetalTextSurface, line: Int) -> CGPoint {
    CGPoint(
      x: surface.surfaceLayout.text.minX + 40,
      y: surface.config.topInset
        + CGFloat(surface.rows.top(ofBlock: 0) - surface.scrollPosition.y)
        + (CGFloat(line) + 0.5) * surface.config.lineHeight)
  }

  /// 印の中心（本文の区画の右端から 8 空けた 18×18 の中心）を、点 `point` と同じ行で。
  func markPoint(_ surface: MetalTextSurface, _ point: CGPoint) -> CGPoint {
    CGPoint(x: surface.surfaceLayout.text.maxX - 8 - 9, y: point.y)
  }

  /// 印を出せる行に乗った間だけ、その行（文書の行か、差し込んだ行）の印が出る。出せない区間の行・何も指さない差し込んだ
  /// 行・絵の差し込みの上では出ない。ポインタが印の上なら印の上の絵になる。行から行へ動かしても、絵の差し込みは描き直さない。
  func testTheMarkShowsOnlyOnMarkableRowsUnderThePointer() throws {
    let setup = try marked()
    let surface = setup.opened.surface
    let asked = setup.thread.widths.count
    surface.hover(at: rowPoint(surface, row: 4))
    XCTAssertEqual(surface.drawn.trailingMark?.row, .document(4))
    surface.hover(at: rowPoint(surface, row: 2))
    XCTAssertNil(surface.drawn.trailingMark, "出せない区間の行")
    surface.hover(at: rowPoint(surface, row: 6))
    XCTAssertNil(surface.drawn.trailingMark, "次の区間は出せない")
    surface.hover(at: insertedPoint(surface, line: 1))
    XCTAssertEqual(surface.drawn.trailingMark?.row, .inserted(block: 0, line: 1))
    surface.hover(at: insertedPoint(surface, line: 0))
    XCTAssertNil(surface.drawn.trailingMark, "出せない差し込んだ行")
    surface.hover(at: insertedPoint(surface, line: 2))
    XCTAssertNil(surface.drawn.trailingMark, "何も指さない差し込んだ行")
    let onRow = rowPoint(surface, row: 5)
    surface.hover(at: onRow)
    let normal = try XCTUnwrap(surface.drawn.trailingMark?.look.images.first?.pixels.key)
    surface.hover(at: markPoint(surface, onRow))
    let hovered = try XCTUnwrap(surface.drawn.trailingMark?.look.images.first?.pixels.key)
    XCTAssertNotEqual(normal, hovered, "印の上の絵")
    surface.hover(at: nil)
    XCTAssertNil(surface.drawn.trailingMark, "面の外")
    XCTAssertEqual(setup.thread.widths.count, asked, "絵の差し込みを描き直さない")
  }

  /// 印は行の右端（本文の区画の右端から 8）の、行の縦の中央に描かれ、外観が変われば絵もその外観で描き直す。
  func testTheMarkIsDrawnAtTheRightEndAndFollowsTheAppearance() throws {
    let setup = try marked()
    let surface = setup.opened.surface
    let point = rowPoint(surface, row: 4)
    surface.hover(at: point)
    let center = markPoint(surface, point)
    var shot = try pixelShot(setup.opened)
    XCTAssertEqual(shot.rgb(center.x, center.y), [255, 0, 0], "暗い外観の絵")
    XCTAssertNotEqual(shot.rgb(center.x - 12, center.y), [255, 0, 0], "印の左の外")
    surface.textView.appearance = NSAppearance(named: .aqua)
    surface.hover(at: point)
    shot = try pixelShot(setup.opened)
    XCTAssertEqual(shot.rgb(center.x, center.y), [0, 0, 255], "明るい外観の絵")
  }

  /// 印を押して同じ印の上で離すと、行つきで 1 回だけ並びの受け手へ知らせ、選択と主は変えない。印の外で離せば知らせない。
  /// 並びを置き直した後は、置き直した並びの受け手だけが受ける。
  func testPressingTheMarkTellsTheTargetOfTheCurrentRows() throws {
    let setup = try marked()
    let (opened, target) = (setup.opened, setup.target)
    let surface = opened.surface
    surface.selectedRange = NSRange(location: 2, length: 0)
    let mark = markPoint(surface, rowPoint(surface, row: 3))
    surface.hover(at: mark)
    try mouse(opened, .leftMouseDown, at: mark)
    try mouse(opened, .leftMouseUp, at: mark)
    XCTAssertEqual(target.pressed, [.document(3)])
    XCTAssertEqual(surface.selectedRange, NSRange(location: 2, length: 0), "選択は変えない")
    let source = markPoint(surface, insertedPoint(surface, line: 1))
    try mouse(opened, .leftMouseDown, at: source)
    try mouse(opened, .leftMouseUp, at: source)
    XCTAssertEqual(target.pressed, [.document(3), .source(1)], "差し込んだ行は出どころの行")
    try mouse(opened, .leftMouseDown, at: mark)
    try mouse(opened, .leftMouseUp, at: rowPoint(surface, row: 3))
    XCTAssertEqual(target.pressed.count, 2, "印の外で離せば知らせない")
    let next = MarkRecorder()
    surface.setRows(
      SurfaceRows(
        spans: [LineSpan(line: 0, allowsTrailingMark: true)], trailingMarkTarget: next))
    try mouse(opened, .leftMouseDown, at: mark)
    try mouse(opened, .leftMouseUp, at: mark)
    XCTAssertEqual(target.pressed.count, 2, "古い並びの受け手へは届かない")
    XCTAssertEqual(next.pressed, [.document(3)])
  }

  /// 表示の構成が印の絵を持たない面と、並びに印を出せる行が無い面では、印は出ず、ポインタの引き直しも起きない。
  func testNoMarkWithoutAPictureOrMarkableRows() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    surface.setRows(SurfaceRows(spans: [LineSpan(line: 0, allowsTrailingMark: true)]))
    surface.hover(at: rowPoint(surface, row: 2))
    XCTAssertNil(surface.drawn.trailingMark, "絵が無い")
    XCTAssertFalse(surface.showsTrailingMarks)
    surface.setPresentation(SurfacePresentation(showsMinimap: false, trailingMark: Self.mark))
    surface.setRows(SurfaceRows(spans: [LineSpan(line: 0)]))
    surface.hover(at: rowPoint(surface, row: 2))
    XCTAssertNil(surface.drawn.trailingMark, "出せる行が無い")
    XCTAssertFalse(surface.showsTrailingMarks)
  }
}
