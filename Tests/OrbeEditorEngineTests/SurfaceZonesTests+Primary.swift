import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 主と点で受ける入口の境——入力欄の選択のドラッグ・字の位置の問い・入力欄の横の外へのドラッグ・入力欄を閉じる知らせ・
/// 焦点の変化・入力欄へ落とすファイル。壊れると、返信欄の選択をドラッグして本文の字が動く・変換中のクリックを IME に
/// 取られる・返信欄のドラッグで本文が横に流れる・返信欄を畳んでも区画が古い高さで並ぶ・焦点の無い窓で返信欄のキャレット
/// が点滅し続ける・返信欄にファイルを落として別の文書が開く。
extension SurfaceZonesTests {
  /// 入力欄の場の文の位置 `offset` のすぐ右の点（view の座標）。
  private func fieldPoint(_ site: EditingSite, _ offset: Int) throws -> CGPoint {
    let rect = site.textRect(
      NSRange(location: offset, length: 0), row: 0, try XCTUnwrap(site.editingEnvironment()),
      marked: nil)
    return CGPoint(x: rect.minX + 0.5, y: rect.midY)
  }

  /// 入力欄の選択の上を押してドラッグしても運ばず（本文の選択も運ばない）、押した所から選び直す。
  func testDraggingFromAFieldSelectionReselectsInTheField() throws {
    let setup = try threaded()
    let (opened, field) = (setup.opened, setup.field)
    let surface = opened.surface
    surface.selectedRange = NSRange(location: 0, length: 5)
    surface.focus(field)
    surface.textView.insertText("abcdefghij")
    surface.textView.selectAll(nil)
    let site = try XCTUnwrap(surface.fields["reply"])
    let body = text(opened.document)
    try mouse(opened, .leftMouseDown, at: try fieldPoint(site, 2))
    try mouse(opened, .leftMouseDragged, at: try fieldPoint(site, 6))
    try mouse(opened, .leftMouseUp, at: try fieldPoint(site, 6))
    XCTAssertEqual(site.editor.state.cursors.primary.selection, NSRange(location: 2, length: 4))
    XCTAssertEqual(field.string, "abcdefghij")
    XCTAssertEqual(text(opened.document), body, "本文は変わらない")
    XCTAssertEqual(surface.editor.state.cursors.primary.selection, NSRange(location: 0, length: 5))
  }

  /// 字の位置の問いは、点の下が主の場のときだけ答える（主でない場の字には NSNotFound）。
  func testCharacterIndexAnswersOnlyOverThePrimarySite() throws {
    let setup = try threaded()
    let (opened, field) = (setup.opened, setup.field)
    let surface = opened.surface
    let view = surface.textView
    let window = try XCTUnwrap(view.window)
    let screen = { (point: CGPoint) in window.convertPoint(toScreen: view.convert(point, to: nil)) }
    surface.focus(field)
    surface.textView.insertText("abcdef")
    let site = try XCTUnwrap(surface.fields["reply"])
    let inField = screen(try fieldPoint(site, 2))
    let inBody = screen(point(opened, row: 1, column: 2))
    XCTAssertEqual(view.characterIndex(for: inField), 2)
    XCTAssertEqual(view.characterIndex(for: inBody), NSNotFound, "主でない本文の字")
    XCTAssertEqual(view.fractionOfDistanceThroughGlyph(for: inBody), 0)
    view.cancelOperation(nil)
    XCTAssertEqual(view.characterIndex(for: inField), NSNotFound, "主でない入力欄の字")
    XCTAssertEqual(view.characterIndex(for: inBody), opened.document.text.lineStart(1) + 2)
  }

  /// 入力欄の選択を本文の区画の左右の外へドラッグしても、自動スクロールせず本文を横に送らない（行末・行頭まで伸ばす）。
  func testDraggingAFieldSelectionSidewaysDoesNotScrollTheBody() throws {
    let opened = try hostedRows(long: true)
    let surface = opened.surface
    let field = ZoneTextField(id: "reply", style: ThreadZone.fieldStyle())
    let thread = ThreadZone(comment: "本文", field: field)
    thread.surface = surface
    surface.setRows(zone(thread, at: 4))
    _ = surface.snapshot()
    XCTAssertGreaterThan(surface.scrollState().limits.maximum.x, 0, "前提: 本文は横に続く")
    surface.focus(field)
    surface.textView.insertText("abcdef")
    let site = try XCTUnwrap(surface.fields["reply"])
    let from = try fieldPoint(site, 1)
    let right = CGPoint(x: surface.view.bounds.width + 20, y: from.y)
    try mouse(opened, .leftMouseDown, at: from)
    try mouse(opened, .leftMouseDragged, at: right)
    XCTAssertFalse(surface.textView.pointer.isAutoscrolling)
    XCTAssertEqual(surface.scrollPosition.x, 0, "本文は横に送らない")
    XCTAssertEqual(site.editor.state.cursors.primary.selection, NSRange(location: 1, length: 5))
    try mouse(opened, .leftMouseUp, at: right)
  }

  /// 入力欄は主になった・外れたを知らせる（押す → Esc → 主にする口 → 絵から消える）。絵から消えて外れた知らせの中で区画を
  /// 描き直せば、その高さは同じ取引の並びに入る。
  func testAFieldNoticesPrimaryChangesAndARedrawInTheLastNoticeSettlesTheRows() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let field = ZoneTextField(id: "reply", style: ThreadZone.fieldStyle())
    var showsField = true
    var height: CGFloat = 60
    let zone = PictureZone { _ in
      ZonePicture(
        height: height,
        elements: showsField
          ? [.field(ZoneField(frame: CGRect(x: 10, y: 10, width: 200, height: 20), field: field))]
          : [])
    }
    var notices: [Bool] = []
    field.didChangePrimary = { _, primary in
      notices.append(primary)
      if !primary, !showsField {
        height = 200
        surface.redrawZone(zone)
      }
    }
    surface.setRows(self.zone(zone, at: 4))
    let at = viewPoint(surface, zone, CGPoint(x: 100, y: 20))
    try mouse(opened, .leftMouseDown, at: at)
    try mouse(opened, .leftMouseUp, at: at)
    surface.textView.cancelOperation(nil)
    surface.focus(field)
    showsField = false
    surface.redrawZone(zone)
    XCTAssertEqual(notices, [true, false, true, false])
    XCTAssertEqual(surface.primary, .body)
    XCTAssertEqual(surface.rows.heights, [200], "外れた知らせの中で描き直した高さ")
    XCTAssertEqual(surface.drawn.rows.heights, [200], "同じ書き込みで材料にも")
  }

  /// Finder のファイルは入力欄へ落とせない（開かず、パスも入れない）。入力欄は文字だけ受ける。
  func testFinderFilesAreRefusedOverAField() throws {
    let setup = try threaded()
    let (opened, thread, field) = (setup.opened, setup.thread, setup.field)
    let surface = opened.surface
    let hostSide = RecordingHost()
    surface.host = hostSide
    let view = surface.textView
    let board = NSPasteboard(name: NSPasteboard.Name("dev.orbe.test.\(UUID().uuidString)"))
    addTeardownBlock { board.releaseGlobally() }
    board.clearContents()
    board.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
    let drag = FakeDraggingInfo(
      at: view.convert(try fieldPoint(opened, thread), to: nil), pasteboard: board,
      operations: .copy)
    XCTAssertEqual(view.draggingUpdated(drag), [])
    XCTAssertFalse(view.performDragOperation(drag))
    XCTAssertTrue(hostSide.openedFiles.isEmpty, "開かない")
    XCTAssertEqual(field.string, "", "パスも入れない")
  }
}
