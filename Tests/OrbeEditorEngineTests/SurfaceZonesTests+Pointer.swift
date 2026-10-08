import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 区画の上のポインタ——区画の文の選択の自動スクロール・押せる場所から選択への切り替え・ポインタの形・主が区画の文の間の
/// サービス。壊れると、コメントを下へ選び続けられない・選べる文に重なるボタンから選べない・押しても効く・ボタンの上で
/// 指の形にならない・コメントを選んでいる間のサービスがソースを書き換える。
extension SurfaceZonesTests {
  /// 区画の文を押して本文の下の外へドラッグすると上下にだけ自動スクロールし、選択はまとまりの端で止まる。
  func testDraggingZoneTextBelowAutoscrollsAndStopsAtTheEndOfTheText() throws {
    let setup = try threaded()
    let (opened, thread) = (setup.opened, setup.thread)
    let surface = opened.surface
    let pointer = surface.textView.pointer
    let line = try XCTUnwrap(surface.zones[ObjectIdentifier(thread)]?.hits.lines.first)
    let from = viewPoint(surface, thread, CGPoint(x: line.x(of: 1) + 0.5, y: line.origin.y - 3))
    let below = CGPoint(x: from.x, y: surface.view.bounds.height + 20)
    try mouse(opened, .leftMouseDown, at: from)
    try mouse(opened, .leftMouseDragged, at: below)
    XCTAssertTrue(pointer.isAutoscrolling)
    pointer.frame(now: 10)
    pointer.frame(now: 10.1)
    XCTAssertGreaterThan(surface.scrollPosition.y, 0, "下へ送る")
    XCTAssertEqual(surface.scrollPosition.x, 0, "横には送らない")
    XCTAssertEqual(
      surface.zoneSelection?.range,
      NSRange(location: 1, length: thread.comment.utf16.count - 1), "まとまりの端で止まる")
    try mouse(opened, .leftMouseUp, at: below)
    XCTAssertFalse(pointer.isAutoscrolling)
  }

  /// 選べる文に重なる押せる場所は、4pt 以内の動きなら押下のまま（主を変えず選ばない）、越えれば押した所からの文の選択になる。
  func testAButtonOverZoneTextTurnsIntoASelectionPastTheSlop() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let font = NSFont.systemFont(ofSize: 12)
    let string = "選べる文の上の押せる場所"
    let zone = PictureZone { _ in
      ZonePicture(
        height: 40,
        elements: [
          .selectable(
            ZoneSelectableLine(
              origin: CGPoint(x: 10, y: 20), text: "t",
              range: NSRange(location: 0, length: string.utf16.count),
              styles: [ZoneTextStyle(length: string.utf16.count, font: font, color: ThreadZone.ink)]
            )),
          .button(ZoneButton(id: "b", frame: CGRect(x: 0, y: 0, width: 300, height: 40))),
        ], texts: [ZoneText(id: "t", string: string)])
    }
    surface.setRows(self.zone(zone, at: 4))
    let down = viewPoint(surface, zone, CGPoint(x: 20, y: 16))
    try mouse(opened, .leftMouseDown, at: down)
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: down.x + 3, y: down.y))
    try mouse(opened, .leftMouseUp, at: CGPoint(x: down.x + 3, y: down.y))
    XCTAssertEqual(surface.primary, .body, "4pt 以内は押下のまま")
    XCTAssertNil(surface.zoneSelection)
    try mouse(opened, .leftMouseDown, at: down)
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: down.x + 40, y: down.y))
    try mouse(opened, .leftMouseUp, at: CGPoint(x: down.x + 40, y: down.y))
    XCTAssertEqual(surface.primary, .zoneText, "越えれば文の選択")
    XCTAssertGreaterThan(surface.zoneSelection?.range.length ?? 0, 0)
  }

  /// 区画の上のポインタの形——押せる場所は載せる側が決めた形、入力欄・選べる文・空きは I ビーム。
  func testThePointerShapeOverAZone() throws {
    let setup = try threaded()
    let (opened, thread) = (setup.opened, setup.thread)
    let surface = opened.surface
    let view = surface.view
    let hits = try XCTUnwrap(surface.zones[ObjectIdentifier(thread)]?.hits)
    let shape = { (local: CGPoint) -> NSCursor in
      NSCursor.arrow.set()
      surface.textView.pointer.updatePointer(
        at: view.convert(self.viewPoint(surface, thread, local), to: nil), flags: [], in: view)
      return NSCursor.current
    }
    let line = hits.lines[0]
    XCTAssertEqual(shape(center(hits.buttons[0].frame)), .pointingHand, "押せる場所")
    XCTAssertEqual(shape(center(hits.fields[0].frame)), .iBeam, "入力欄")
    XCTAssertEqual(shape(CGPoint(x: line.origin.x + 2, y: line.origin.y - 3)), .iBeam, "選べる文")
    XCTAssertEqual(shape(CGPoint(x: 10, y: 10)), .iBeam, "空き")
  }

  /// 主が区画の文の間、サービスは選んだ区画の文を送るだけで、受ける（書き換える）ことはしない。
  func testServicesOnlyReadTheZoneSelection() throws {
    let setup = try threaded()
    let (opened, thread, field) = (setup.opened, setup.thread, setup.field)
    let surface = opened.surface
    let view = surface.textView
    let line = try XCTUnwrap(surface.zones[ObjectIdentifier(thread)]?.hits.lines.first)
    let from = viewPoint(surface, thread, CGPoint(x: line.x(of: 2) + 0.5, y: line.origin.y - 3))
    let to = viewPoint(surface, thread, CGPoint(x: line.x(of: 6) + 0.5, y: line.origin.y - 3))
    try mouse(opened, .leftMouseDown, at: from)
    try mouse(opened, .leftMouseDragged, at: to)
    try mouse(opened, .leftMouseUp, at: to)
    XCTAssertEqual(surface.primary, .zoneText, "前提")
    XCTAssertTrue(view.validRequestor(forSendType: .string, returnType: nil) as AnyObject === view)
    XCTAssertFalse(
      view.validRequestor(forSendType: .string, returnType: .string) as AnyObject === view,
      "受ける口は出さない")
    let board = NSPasteboard(name: NSPasteboard.Name("dev.orbe.test.\(UUID().uuidString)"))
    addTeardownBlock { board.releaseGlobally() }
    XCTAssertTrue(view.writeSelection(to: board, types: [.string]))
    XCTAssertEqual(board.string(forType: .string), "る本文の")
    let body = text(opened.document)
    board.declareTypes([.string], owner: nil)
    board.setString("書き換え", forType: .string)
    XCTAssertFalse(view.readSelection(from: board))
    XCTAssertEqual(text(opened.document), body)
    XCTAssertEqual(field.string, "")
  }
}
