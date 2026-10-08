import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 区画の入力欄と区画の文の選択——主（キーと IME の行き先）の遷移と、入力欄の場の打鍵・IME・undo、区画の文の選択と
/// コピー、主が区画の文の間に効くコマンド。壊れると、返信の打鍵がソースへ入る・返信の undo が本文を戻す・コメントを
/// 選んでいる間のキーで本文が変わる・入力欄が伸びるコマに字が遅れる。
extension SurfaceZonesTests {
  /// 返信の入力欄つきのスレッドを行 4 の前に置いた面。
  struct Threaded {
    let opened: Opened
    let thread: ThreadZone
    let field: ZoneTextField
  }

  func threaded() throws -> Threaded {
    let opened = try hostedRows()
    let field = ZoneTextField(id: "reply", style: ThreadZone.fieldStyle())
    let thread = ThreadZone(comment: "選べる本文の文。二行目まで続く長さの文にする。", field: field)
    thread.surface = opened.surface
    opened.surface.setRows(zone(thread, at: 4))
    return Threaded(opened: opened, thread: thread, field: field)
  }

  func fieldPoint(_ opened: Opened, _ thread: ThreadZone) throws -> CGPoint {
    let hits = try XCTUnwrap(opened.surface.zones[ObjectIdentifier(thread)]?.hits)
    return viewPoint(opened.surface, thread, center(hits.fields[0].frame))
  }

  /// 入力欄を押すと主が入力欄になり、打鍵・削除・undo は入力欄の文に入って本文は変わらない。Esc で本文が主に戻り、続きの
  /// 打鍵は本文に入る。
  func testTypingIntoAFieldGoesToTheField() throws {
    let setup = try threaded()
    let (opened, thread, field) = (setup.opened, setup.thread, setup.field)
    let surface = opened.surface
    let view = surface.textView
    let at = try fieldPoint(opened, thread)
    try mouse(opened, .leftMouseDown, at: at)
    try mouse(opened, .leftMouseUp, at: at)
    XCTAssertEqual(surface.primary, .field("reply"))
    let body = text(opened.document)
    view.insertText("返信")
    view.deleteBackward(nil)
    XCTAssertEqual(field.string, "返")
    XCTAssertEqual(text(opened.document), body, "本文は変わらない")
    view.undo(nil)
    XCTAssertEqual(field.string, "返信", "undo は入力欄の場の履歴")
    view.undo(nil)
    XCTAssertEqual(field.string, "")
    XCTAssertEqual(text(opened.document), body)
    view.cancelOperation(nil)
    XCTAssertEqual(surface.primary, .body, "Esc で本文へ")
    view.insertText("z")
    XCTAssertEqual(field.string, "")
    XCTAssertNotEqual(text(opened.document), body, "続きは本文に入る")
  }

  /// 本文が読むだけでも、入力欄は打て（IME の文脈もある）、undo できる。本文は変わらない。
  func testAFieldTakesTypingOnAReadOnlySurface() throws {
    let setup = try threaded()
    let (opened, thread, field) = (setup.opened, setup.thread, setup.field)
    let view = opened.surface.textView
    opened.surface.isEditable = false
    let at = try fieldPoint(opened, thread)
    try mouse(opened, .leftMouseDown, at: at)
    try mouse(opened, .leftMouseUp, at: at)
    XCTAssertNotNil(view.inputContext, "入力欄は文脈を返す")
    let body = text(opened.document)
    view.insertText("返信")
    XCTAssertEqual(field.string, "返信")
    XCTAssertTrue(
      view.validateMenuItem(
        NSMenuItem(title: "", action: #selector(MetalTextView.undo(_:)), keyEquivalent: "")))
    view.undo(nil)
    XCTAssertEqual(field.string, "")
    view.cancelOperation(nil)
    view.insertText("z")
    XCTAssertEqual(text(opened.document), body, "本文は変わらない")
  }

  /// 改行で入力欄が伸びるとき、伸びた区画（並びの高さ）と打った字は同じ書き込みで材料に入る。入力欄のキャレットは主の
  /// 間だけ描き、本文のキャレットは描かない。
  func testAFieldGrowsInTheSameWriteAsTheKeystroke() throws {
    let setup = try threaded()
    let (opened, thread, field) = (setup.opened, setup.thread, setup.field)
    let surface = opened.surface
    surface.updateFocus(true)
    surface.focus(field)
    let height = surface.rows.heights[0]
    let revision = surface.drawn.revision
    surface.textView.insertText("一行目")
    surface.textView.insertNewline(nil)
    let material = surface.material.read()
    XCTAssertEqual(material.revision, revision + 2, "打鍵ごとに 1 回だけ書く")
    XCTAssertGreaterThan(material.rows.heights[0], height, "伸びた入力欄")
    let site = try XCTUnwrap(surface.fields["reply"])
    let fieldMaterial = try XCTUnwrap(material.fields[site.serial])
    XCTAssertEqual(fieldMaterial.content.text.lineCount, 2, "打った字と同じ書き込み")
    XCTAssertTrue(fieldMaterial.caret.focused, "入力欄のキャレットを描く")
    XCTAssertFalse(material.caret.focused, "本文のキャレットは描かず、選択は焦点の無い色")
    XCTAssertEqual(thread.field?.lineCount, 2)
  }

  /// 入力欄の幅を越える行を打つと、描いたコマで入力欄の横の送りがキャレットの見えるところまで寄り、行頭へ戻れば戻る。
  func testALongLineInAFieldScrollsToTheCaret() throws {
    let setup = try threaded()
    let (surface, field) = (setup.opened.surface, setup.field)
    surface.focus(field)
    let site = try XCTUnwrap(surface.fields["reply"])
    surface.textView.insertText(String(repeating: "長い返信の行。", count: 40))
    _ = surface.snapshot()
    XCTAssertGreaterThan(site.scrollX, 0, "キャレットへ寄る")
    let width = Double(site.frame.width)
    let caretX =
      Double(
        site.textRect(
          NSRange(location: field.text.length, length: 0), row: 0,
          try XCTUnwrap(site.editingEnvironment()),
          marked: nil
        ).minX - (site.fieldOrigin()?.x ?? 0)) - site.scrollX
    XCTAssertTrue((0...width).contains(caretX), "キャレットは入力欄の幅の中")
    surface.textView.moveToBeginningOfLine(nil)
    _ = surface.snapshot()
    XCTAssertEqual(site.scrollX, 0, "行頭へ戻れば送りも戻る")
  }

  /// 入力欄で変換すると未確定は入力欄の文に入り（本文は変わらない）、view の入力の文脈は入力欄の場のもの。確定の後の undo は
  /// 変換の正味を 1 回で戻す。
  func testComposingInAField() throws {
    let setup = try threaded()
    let (opened, field) = (setup.opened, setup.field)
    let surface = opened.surface
    surface.focus(field)
    let site = try XCTUnwrap(surface.fields["reply"])
    let context = FakeInputContext(client: surface.textView)
    site.inputContext = context
    XCTAssertTrue(surface.textView.inputContext === context, "主の場の文脈")
    let body = text(opened.document)
    for call: IMECall in [.mark("へ"), .mark("へん"), .mark("変"), .insert("変")] {
      call.send(to: surface.textView)
    }
    XCTAssertEqual(field.string, "変")
    XCTAssertEqual(text(opened.document), body)
    surface.textView.undo(nil)
    XCTAssertEqual(field.string, "")
    surface.textView.cancelOperation(nil)
    XCTAssertFalse(surface.textView.inputContext === context, "本文が主なら本文の文脈")
  }

  /// 入力欄で変換している間、IME の文字の矩形は入力欄のキャレットの位置で、面をスクロールしても主と変換は保たれ、
  /// 矩形はスクロールに付いて動く。
  func testTheInputMethodRectFollowsTheFieldCaretAcrossScrolling() throws {
    let setup = try threaded()
    let (opened, thread, field) = (setup.opened, setup.thread, setup.field)
    let surface = opened.surface
    let view = surface.textView
    surface.focus(field)
    let site = try XCTUnwrap(surface.fields["reply"])
    site.inputContext = FakeInputContext(client: view)
    IMECall.mark("かな").send(to: view)
    let window = try XCTUnwrap(view.window)
    let rect = { () -> NSRect in
      let screen = view.firstRect(
        forCharacterRange: NSRange(location: 2, length: 0), actualRange: nil)
      return view.convert(window.convertFromScreen(screen), from: nil)
    }
    let hits = try XCTUnwrap(surface.zones[ObjectIdentifier(thread)]?.hits)
    let origin = viewPoint(surface, thread, hits.fields[0].frame.origin)
    var shown = rect()
    XCTAssertEqual(shown.minY, origin.y, accuracy: 0.5, "入力欄の 1 行目")
    XCTAssertGreaterThan(shown.minX, origin.x + 10, "未確定の字の後ろ")
    surface.scroll(toFirstLine: 2)
    XCTAssertEqual(surface.primary, .field("reply"))
    XCTAssertTrue(site.editor.isComposing, "スクロールしても変換は続く")
    shown = rect()
    XCTAssertEqual(shown.minY, origin.y - 36, accuracy: 0.5, "スクロールに付いて動く")
  }

  /// 区画の文をドラッグで選ぶと主が区画の文になり、⌘C で選んだまとまりの文の部分が写る。主が区画の文の間は ⌘C・⌘A・Esc
  /// だけが効き、打鍵や貼るは本文にも入力欄にも効かない（メニューも無効）。Esc で本文へ戻り、選択は解ける。
  func testSelectingZoneTextAndCopying() throws {
    let setup = try threaded()
    let (opened, thread, field) = (setup.opened, setup.thread, setup.field)
    let surface = opened.surface
    let view = surface.textView
    let board = privatePasteboard(opened)
    let hits = try XCTUnwrap(surface.zones[ObjectIdentifier(thread)]?.hits)
    let line = hits.lines[0]
    let from = viewPoint(surface, thread, CGPoint(x: line.x(of: 2) + 0.5, y: line.origin.y - 3))
    let to = viewPoint(surface, thread, CGPoint(x: line.x(of: 6) + 0.5, y: line.origin.y - 3))
    try mouse(opened, .leftMouseDown, at: from)
    try mouse(opened, .leftMouseDragged, at: to)
    try mouse(opened, .leftMouseUp, at: to)
    XCTAssertEqual(surface.primary, .zoneText)
    XCTAssertEqual(surface.zoneSelection?.range, NSRange(location: 2, length: 4))
    view.copy(nil)
    XCTAssertEqual(board.string(forType: .string), "る本文の")
    let body = text(opened.document)
    view.insertText("x")
    view.deleteBackward(nil)
    board.clearContents()
    board.setString("貼る", forType: .string)
    view.paste(nil)
    XCTAssertEqual(text(opened.document), body, "本文は変わらない")
    XCTAssertEqual(field.string, "", "入力欄も変わらない")
    let paste = NSMenuItem(title: "", action: #selector(view.paste(_:)), keyEquivalent: "")
    let copy = NSMenuItem(title: "", action: #selector(view.copy(_:)), keyEquivalent: "")
    XCTAssertFalse(view.validateMenuItem(paste))
    XCTAssertTrue(view.validateMenuItem(copy))
    view.selectAll(nil)
    XCTAssertEqual(surface.zoneSelection?.range.length, thread.comment.utf16.count, "まとまり全体")
    XCTAssertNotNil(surface.drawn.zoneSelection)
    view.cancelOperation(nil)
    XCTAssertEqual(surface.primary, .body)
    XCTAssertNil(surface.zoneSelection)
    XCTAssertNil(surface.drawn.zoneSelection, "選択の地も消える")
  }

  /// 契約の選択の口は（同じ値でも）主を本文に戻す。本文の丸ごとの置き換えは主を変えず、続きの打鍵は入力欄に入る。
  func testContractSelectionReturnsToTheBodyButReplaceAllDoesNot() throws {
    let setup = try threaded()
    let (opened, field) = (setup.opened, setup.field)
    let surface = opened.surface
    surface.focus(field)
    surface.replaceAll(with: "外で書き換えた本文\n")
    XCTAssertEqual(surface.primary, .field("reply"))
    surface.textView.insertText("続き")
    XCTAssertEqual(field.string, "続き")
    XCTAssertEqual(text(opened.document), "外で書き換えた本文\n")
    surface.selectedRange = surface.selectedRange
    XCTAssertEqual(surface.primary, .body)
  }

  /// 入力欄を外から置き換える口は場の丸ごとの置き換え（undo の区切りを通る）で、主にする口は主を入力欄にする。絵から
  /// 入力欄が消えれば場を閉じ、主は本文に戻る。
  func testReplacingFocusingAndClosingAField() throws {
    let setup = try threaded()
    let (opened, thread, field) = (setup.opened, setup.thread, setup.field)
    let surface = opened.surface
    surface.focus(field)
    surface.textView.insertText("送る文")
    surface.replaceText(of: field, with: "")
    XCTAssertEqual(field.string, "")
    surface.textView.undo(nil)
    XCTAssertEqual(field.string, "送る文", "置き換えは undo に載る")
    let replacement = ThreadZone(comment: thread.comment)
    surface.setRows(zone(replacement, at: 4))
    XCTAssertNil(surface.fields["reply"], "絵に無い入力欄の場は閉じる")
    XCTAssertEqual(surface.primary, .body)
    XCTAssertTrue(surface.drawn.fields.isEmpty)
  }

  /// 入力欄の下端の近くで改行して入力欄が伸び、キャレットが面の下端を越えれば、面がキャレットの見えるところまで送る。
  func testANewlineBelowTheViewportScrollsTheFieldCaretIntoView() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let view = surface.textView
    let field = ZoneTextField(id: "reply", style: ThreadZone.fieldStyle())
    let thread = ThreadZone(comment: "本文", field: field)
    thread.surface = surface
    surface.setRows(zone(thread, at: 16))
    surface.focus(field)
    let window = try XCTUnwrap(view.window)
    let caret = { () -> NSRect in
      let screen = view.firstRect(
        forCharacterRange: NSRange(location: field.text.length, length: 0), actualRange: nil)
      return view.convert(window.convertFromScreen(screen), from: nil)
    }
    XCTAssertLessThan(caret().maxY, view.bounds.height, "前提: 入力欄のキャレットは見えている")
    for _ in 0..<6 { view.insertNewline(nil) }
    XCTAssertGreaterThan(surface.scrollPosition.y, 0, "面が送られた")
    let shown = caret()
    XCTAssertGreaterThanOrEqual(shown.minY, 0)
    XCTAssertLessThanOrEqual(shown.maxY, view.bounds.height, "キャレットが面の中に見える")
  }

  /// 字を落とせるのは区画の中では入力欄だけで、落とせば入力欄に入って主が入力欄になる。区画の文・押せる場所・空きへは
  /// 落とせず、本文も入力欄も変わらない。
  func testDroppingTextGoesIntoAFieldButNotElsewhereInAZone() throws {
    let setup = try threaded()
    let (opened, thread, field) = (setup.opened, setup.thread, setup.field)
    let surface = opened.surface
    let view = surface.textView
    let board = NSPasteboard(name: NSPasteboard.Name("dev.orbe.test.\(UUID().uuidString)"))
    addTeardownBlock { board.releaseGlobally() }
    board.clearContents()
    board.setString("落とす", forType: .string)
    let hits = try XCTUnwrap(surface.zones[ObjectIdentifier(thread)]?.hits)
    let line = hits.lines[0]
    let refused = [
      CGPoint(x: line.origin.x + 2, y: line.origin.y - 3), center(hits.buttons[0].frame),
      CGPoint(x: 10, y: 10),
    ]
    let body = text(opened.document)
    for local in refused {
      let drag = FakeDraggingInfo(
        at: view.convert(viewPoint(surface, thread, local), to: nil), pasteboard: board,
        operations: .copy)
      XCTAssertEqual(view.draggingUpdated(drag), [], "\(local) へは落とせない")
      XCTAssertFalse(view.performDragOperation(drag))
    }
    XCTAssertEqual(text(opened.document), body)
    XCTAssertEqual(field.string, "")
    let drag = FakeDraggingInfo(
      at: view.convert(try fieldPoint(opened, thread), to: nil), pasteboard: board,
      operations: .copy)
    XCTAssertEqual(view.draggingUpdated(drag), .copy)
    XCTAssertTrue(view.performDragOperation(drag))
    XCTAssertEqual(field.string, "落とす")
    XCTAssertEqual(surface.primary, .field("reply"))
    XCTAssertEqual(text(opened.document), body, "本文は変わらない")
  }
}
