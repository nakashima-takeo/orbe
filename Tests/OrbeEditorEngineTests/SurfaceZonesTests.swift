import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 区画（載せる側の絵を本文と同じコマに描く差し込み）——絵を問う幅と高さ・本文と同じ位置への描き方・幅や中身の変化での
/// 問い直し・上端の影と横スクロールバーとの重ね順・点の下の行き先（入力欄・押せる場所・選べる文・空き）・押せる場所の
/// ホバーと押下。壊れると、PR のスレッドが本文の行に重なる・ずれて動く・幅を変えても高さが中身に合わない・ボタンが効かない。
@MainActor
final class SurfaceZonesTests: EngineTestCase {
  private let size = CGSize(width: 600, height: 400)

  /// ミニマップを出さない面を窓に載せる（`count` 行）。
  func hostedRows(_ count: Int = 80, long: Bool = false) throws -> Opened {
    let opened = try open(rows(count, width: long ? 400 : 10), size: size)
    opened.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    _ = host(opened, size: size)
    return opened
  }

  func zone(_ zone: SurfaceZone, at line: Int) -> SurfaceRows {
    SurfaceRows(insertions: [RowInsertion(line: line, content: .zone(zone))])
  }

  /// 区画の高さは本文の区画の幅で問うた絵の高さで、下の文書の行はその高さだけ下がる。区画の箱は並びの y − スクロールの
  /// 位置に、本文と同じコマに描かれる。
  func testAZoneIsAskedAtTheTextWidthAndDrawnWithTheText() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let box = BoxZone(height: 50)
    surface.setRows(zone(box, at: 4))
    XCTAssertEqual(box.widths, [surface.surfaceLayout.text.width])
    XCTAssertEqual(surface.rows.heights, [50])
    XCTAssertEqual(surface.rows.y(ofLine: 4), 4 * 18 + 50)
    let x = surface.surfaceLayout.text.minX + 30
    let top = surface.config.topInset + CGFloat(surface.rows.top(ofBlock: 0))
    var shot = try pixelShot(opened)
    XCTAssertEqual(shot.rgb(x, top + 1), [255, 0, 0], "区画の上端の内側")
    XCTAssertEqual(shot.rgb(x, top + 49), [255, 0, 0], "区画の下端の内側")
    XCTAssertNotEqual(shot.rgb(x, top - 1), [255, 0, 0], "上の行は区画の外")
    XCTAssertNotEqual(shot.rgb(x, top + 51), [255, 0, 0], "下の行は区画の外")
    surface.scroll(toFirstLine: 2.5)
    shot = try pixelShot(opened)
    XCTAssertEqual(shot.rgb(x, top - 2.5 * 18 + 1), [255, 0, 0], "スクロールしても本文と同じ位置")
    XCTAssertNotEqual(shot.rgb(x, top - 2.5 * 18 - 1), [255, 0, 0])
  }

  /// 載せる側が描き直すと言えば絵を問い直し、見えている先頭の文書の行より上の区画が伸びても、その行の画面上の位置は
  /// 変わらない。置いていない区画は何もしない。
  func testRedrawingAZoneAboveKeepsTheFirstVisibleLine() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let box = BoxZone(height: 40)
    surface.setRows(zone(box, at: 5))
    surface.scroll(toFirstLine: 20)
    surface.flush()
    let offset = surface.scrollPosition.y - surface.rows.y(ofLine: 20)
    box.height = 90
    surface.redrawZone(box)
    surface.flush()
    XCTAssertEqual(surface.rows.heights, [90])
    XCTAssertEqual(surface.scrollPosition.y - surface.rows.y(ofLine: 20), offset, accuracy: 1e-9)
    surface.redrawZone(BoxZone(height: 10))
    XCTAssertEqual(surface.rows.heights, [90], "置いていない区画は何もしない")
  }

  /// 本文の区画の幅が変われば（窓の幅・行番号の桁）絵を問い直す（折り返しが変わり、高さが合う）。
  func testAZoneIsAskedAgainWhenTheTextWidthChanges() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let thread = ThreadZone(
      comment: String(repeating: "幅で折り返す本文。", count: 12))
    surface.setRows(zone(thread, at: 3))
    let wide = surface.rows.heights[0]
    surface.viewStateDidChange(size: CGSize(width: 320, height: 400), scale: 2, visible: false)
    XCTAssertEqual(thread.widths.count, 2)
    XCTAssertEqual(thread.widths.last, surface.surfaceLayout.text.width)
    XCTAssertGreaterThan(surface.rows.heights[0], wide, "狭くなれば折り返しが増えて高くなる")
    let narrow = surface.surfaceLayout.text.width
    surface.replaceAll(with: rows(10_000))
    XCTAssertLessThan(surface.surfaceLayout.text.width, narrow, "前提: 行番号の桁が増えた")
    XCTAssertEqual(thread.widths.last, surface.surfaceLayout.text.width, "桁が増えた幅で問い直す")
  }

  /// 区画は上端の影と横スクロールバーの下に描かれる（区画のある面でも影は Metal が描く）。
  func testTheTopShadowAndTheHorizontalScrollbarStayAboveZones() throws {
    let opened = try hostedRows(long: true)
    let surface = opened.surface
    let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    surface.setRows(zone(BoxZone(height: 400, color: white), at: 2))
    surface.scroll(toFirstLine: 3)
    let shot = try pixelShot(opened)
    let x = surface.surfaceLayout.text.minX + 100
    XCTAssertEqual(shot.rgb(x, 30), [255, 255, 255], "前提: 区画の白")
    XCTAssertLessThan(shot.rgb(x, 0.5)[0], 250, "上端の影が区画の上に出る")
    XCTAssertGreaterThan(surface.scrollState().limits.maximum.x, 0, "前提: 横に続く")
    let bar = surface.surfaceLayout.horizontalScrollbar
    XCTAssertNotEqual(shot.rgb(x, bar.maxY - 1), [255, 255, 255], "横スクロールバーの縁が区画の上に出る")
  }

  /// 点の下の行き先——区画の上は、入力欄 → 押せる場所 → 選べる文 → 空き。区画の外は本文。区画の空きの当たりは次の文書の
  /// 行の行頭で、区画の字には当たらない。
  func testPointsOverAZoneTargetFieldsButtonsTextAndSpace() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let field = ZoneTextField(id: "reply", style: ThreadZone.fieldStyle())
    let thread = ThreadZone(comment: "選べる本文", field: field)
    surface.setRows(zone(thread, at: 4))
    let hits = try XCTUnwrap(surface.zones[ObjectIdentifier(thread)]?.hits)
    let point = { (local: CGPoint) in self.viewPoint(surface, thread, local) }
    guard case .field(let site) = surface.target(at: point(center(hits.fields[0].frame))) else {
      return XCTFail("入力欄")
    }
    XCTAssertTrue(site.field === field)
    guard case .button(_, let button) = surface.target(at: point(center(hits.buttons[0].frame)))
    else { return XCTFail("押せる場所") }
    XCTAssertEqual(button.id, ThreadZone.resolve)
    let line = hits.lines[0]
    guard
      case .zoneText(_, let text, let offset) = surface.target(
        at: point(CGPoint(x: line.origin.x + 1, y: line.origin.y - 3)))
    else { return XCTFail("選べる文") }
    XCTAssertEqual(text, ThreadZone.commentText)
    XCTAssertEqual(offset, 0)
    let space = point(CGPoint(x: 10, y: 10))
    guard case .zoneSpace = surface.target(at: space) else { return XCTFail("区画の空き") }
    XCTAssertEqual(surface.hit(space)?.offset, opened.document.text.lineStart(4))
    XCTAssertNil(surface.character(at: space))
    guard case .body = surface.target(at: point(CGPoint(x: 10, y: -5))) else {
      return XCTFail("区画の外は本文")
    }
  }

  /// 押せる場所——ポインタが入る・出るを知らせ、押して同じ押せる場所で離せば押下を知らせる（ずらして離せば知らせない）。
  /// 押下は主を変えない。
  func testButtonsGetHoverAndPress() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let field = ZoneTextField(id: "reply", style: ThreadZone.fieldStyle())
    let thread = ThreadZone(comment: "本文", field: field)
    surface.setRows(zone(thread, at: 4))
    let hits = try XCTUnwrap(surface.zones[ObjectIdentifier(thread)]?.hits)
    let resolve = viewPoint(surface, thread, center(hits.buttons[0].frame))
    surface.focus(field)
    surface.hover(at: resolve)
    XCTAssertEqual(thread.events, [.entered(ThreadZone.resolve)])
    surface.hover(at: viewPoint(surface, thread, CGPoint(x: 5, y: 5)))
    XCTAssertEqual(thread.events.last, .exited(ThreadZone.resolve))
    try mouse(opened, .leftMouseDown, at: resolve)
    try mouse(opened, .leftMouseUp, at: resolve)
    XCTAssertEqual(thread.events.last, .pressed(ThreadZone.resolve))
    XCTAssertEqual(surface.primary, .field("reply"), "押下は主を変えない")
    let count = thread.events.count
    try mouse(opened, .leftMouseDown, at: resolve)
    try mouse(opened, .leftMouseUp, at: viewPoint(surface, thread, CGPoint(x: 5, y: 5)))
    XCTAssertEqual(thread.events.count, count, "外で離せば押下でない")
  }

  /// 区画の座標 `local` の、面の view の座標。
  func viewPoint(_ surface: MetalTextSurface, _ zone: SurfaceZone, _ local: CGPoint) -> CGPoint {
    let block = surface.rows.block(ofZone: ObjectIdentifier(zone)) ?? 0
    return CGPoint(
      x: surface.surfaceLayout.text.minX + local.x,
      y: surface.config.topInset
        + CGFloat(surface.rows.top(ofBlock: block) - surface.scrollPosition.y)
        + local.y)
  }

  func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}
