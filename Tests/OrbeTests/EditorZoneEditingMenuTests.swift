import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 標準の編集操作（⌘A ⌘C ⌘X ⌘V ⌘Z ⌘⇧Z と右クリックのメニュー）が、アプリの経路——窓の view の階層が key equivalent を
/// 取らずにメインメニューへ渡し、編集メニュー（`MainMenu`）の項目が first responder の連鎖へセレクタを配る——で、主
/// （本文・区画の文・返信の入力欄）に従って効く。壊れると、返信の入力欄で貼れない・全部を選べない、コメントを選んで
/// いる間の ⌘V や ⌘Z で本文が変わる。
@MainActor
final class EditorZoneEditingMenuTests: OrbeTestCase {
  private struct Scene {
    let window: NSWindow
    let document: EditorDocument
    let surface: MetalTextSurface
    let thread: SampleThreadZone
  }

  private static let source = "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\n"

  private func scene() throws -> Scene {
    let tab = TerminalTab(
      cwd: TestScratch.caseDir.path,
      editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900, height: 600)
    let document = try tab.editor.open(try caseFile("menu.swift", Self.source), as: .pinned)
    catchUp(document)
    let surface = try engine(document)
    surface.setPresentation(SurfacePresentation(showsMinimap: false))
    let thread = SampleThreadZone.sample(line: 2, id: "reply")
    thread.surface = surface
    surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 2, content: .zone(thread))]))
    surface.textView.pasteboard = NSPasteboard(name: .init("orbe-test-\(UUID().uuidString)"))
    window.makeFirstResponder(surface.responder)
    surface.flush()
    return Scene(window: window, document: document, surface: surface, thread: thread)
  }

  /// 編集メニューの key equivalent を押す。窓の view の階層は取らず（取ればメニューへ届かない）、メニューの項目が有効
  /// なら first responder の連鎖のセレクタを呼ぶ（AppKit の target=nil の配り方）。項目が有効だったかを返す。
  @discardableResult
  private func press(
    _ key: String, _ flags: NSEvent.ModifierFlags = .command, _ scene: Scene,
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> Bool {
    XCTAssertFalse(
      scene.window.performKeyEquivalent(with: .key(key, flags)),
      "⌘\(key) は view の階層で取られずメインメニューへ渡る", file: file, line: line)
    let edit = try XCTUnwrap(
      MainMenu.build(appName: "Orbe", language: .ja).items[1].submenu, file: file, line: line)
    let item = try XCTUnwrap(
      edit.items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == flags },
      "編集メニューに ⌘\(key) がある", file: file, line: line)
    return try send(item, scene, file: file, line: line)
  }

  /// 右クリックのメニュー（点 `point` は区画の中の座標、nil なら本文の行 0）を出し、セレクタが `action` の項目を選ぶ。
  /// 項目が有効だったかを返す（項目が無ければ nil）。
  private func contextMenu(
    at point: CGPoint?, choose action: Selector, _ scene: Scene,
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> Bool? {
    let surface = scene.surface
    let local =
      point.map { viewPoint(scene, $0) }
      ?? CGPoint(x: surface.surfaceLayout.text.minX + 30, y: surface.config.topInset + 5)
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: surface.textView.convert(local, to: nil),
        modifierFlags: [], timestamp: 0, windowNumber: scene.window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1), file: file, line: line)
    let menu = try XCTUnwrap(surface.textView.menu(for: event), file: file, line: line)
    guard let item = menu.items.first(where: { $0.action == action }) else { return nil }
    XCTAssertNil(item.target, "右クリックの項目も first responder の連鎖へ配る", file: file, line: line)
    return try send(item, scene, file: file, line: line)
  }

  private func send(
    _ item: NSMenuItem, _ scene: Scene, file: StaticString, line: UInt
  ) throws -> Bool {
    let action = try XCTUnwrap(item.action, file: file, line: line)
    var responder = scene.window.firstResponder
    while let current = responder, !current.responds(to: action) {
      responder = current.nextResponder
    }
    let target = try XCTUnwrap(responder, "連鎖に \(action) の受け手がいる", file: file, line: line)
    guard (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true else { return false }
    _ = target.perform(action, with: item)
    return true
  }

  private func viewPoint(_ scene: Scene, _ local: CGPoint) -> CGPoint {
    let surface = scene.surface
    let block = surface.rows.block(ofZone: ObjectIdentifier(scene.thread)) ?? 0
    return CGPoint(
      x: surface.surfaceLayout.text.minX + local.x,
      y: surface.config.topInset
        + CGFloat(surface.rows.top(ofBlock: block) - surface.scrollPosition.y) + local.y)
  }

  private func hits(_ scene: Scene) throws -> ZoneHits {
    try XCTUnwrap(scene.surface.zones[ObjectIdentifier(scene.thread)]?.hits)
  }

  /// 文書の本文（主が入力欄でも本文を読む。入力の口は主の場を読むので使わない）。
  private func documentText(_ scene: Scene) -> String {
    let text = scene.document.text
    return text.substring(NSRange(location: 0, length: text.length))
  }

  private func clipboard(_ scene: Scene) -> String? {
    scene.surface.textView.pasteboard.string(forType: .string)
  }

  /// 返信の入力欄が主の間、⌘A ⌘C ⌘X ⌘V ⌘Z ⌘⇧Z と右クリックの貼り付けは入力欄の文に効き、本文は変わらない。
  func testEditingKeysAndTheContextMenuWorkInTheReplyField() throws {
    let scene = try scene()
    let field = scene.thread.field
    let reply = field.string
    scene.surface.focus(field)
    let site = try XCTUnwrap(scene.surface.fields["reply"])
    XCTAssertTrue(try press("a", .command, scene))
    XCTAssertEqual(
      site.editor.state.cursors.primary.selection, NSRange(location: 0, length: field.text.length),
      "⌘A は入力欄の文を全部選ぶ")
    XCTAssertTrue(try press("c", .command, scene))
    XCTAssertEqual(clipboard(scene), reply, "⌘C は入力欄の選択を写す")
    XCTAssertTrue(try press("x", .command, scene))
    XCTAssertEqual(field.string, "", "⌘X は入力欄の選択を切り取る")
    XCTAssertTrue(try press("v", .command, scene))
    XCTAssertEqual(field.string, reply, "⌘V は入力欄に貼る")
    XCTAssertTrue(try press("z", .command, scene))
    XCTAssertEqual(field.string, "", "⌘Z は入力欄の履歴を戻す")
    XCTAssertTrue(try press("z", [.command, .shift], scene))
    XCTAssertEqual(field.string, reply, "⌘⇧Z は入力欄の履歴をやり直す")
    let frame = try hits(scene).fields[0].frame
    XCTAssertEqual(
      try contextMenu(
        at: CGPoint(x: frame.maxX - 4, y: frame.midY), choose: #selector(NSText.paste(_:)), scene),
      true)
    XCTAssertEqual(field.string, reply + reply, "右クリックのペーストは入力欄の末尾に貼る")
    XCTAssertEqual(scene.surface.primary, .field("reply"))
    XCTAssertEqual(documentText(scene), Self.source, "本文は変わらない")
  }

  /// 区画の文が主の間は、⌘A（まとまり全体）と ⌘C・右クリックのコピーだけが効き、⌘X ⌘V ⌘Z は無効で本文も入力欄も
  /// 変わらない。
  func testOnlySelectAllAndCopyWorkOnZoneText() throws {
    let scene = try scene()
    let body = try XCTUnwrap(try hits(scene).lines.first { $0.text == AnyHashable("body-0") })
    let at = CGPoint(x: body.origin.x + 20, y: body.origin.y - 4)
    XCTAssertEqual(
      try contextMenu(at: at, choose: #selector(NSText.paste(_:)), scene), nil, "区画の文のメニューにペーストは無い")
    XCTAssertEqual(scene.surface.primary, .zoneText)
    XCTAssertTrue(try press("a", .command, scene))
    XCTAssertTrue(try press("c", .command, scene))
    let copied = try XCTUnwrap(clipboard(scene))
    XCTAssertTrue(copied.hasPrefix("tail だけ見ると"), "⌘A ⌘C はコメントの本文全体を写す: \(copied)")
    XCTAssertTrue(copied.contains("merges(event)"))
    scene.surface.textView.pasteboard.clearContents()
    XCTAssertEqual(try contextMenu(at: at, choose: #selector(NSText.copy(_:)), scene), true)
    XCTAssertEqual(clipboard(scene), copied, "右クリックのコピーは選んだ文を写す")
    let reply = scene.thread.field.string
    XCTAssertFalse(try press("x", .command, scene))
    XCTAssertFalse(try press("v", .command, scene))
    XCTAssertFalse(try press("z", .command, scene))
    XCTAssertEqual(documentText(scene), Self.source, "本文は変わらない")
    XCTAssertEqual(scene.thread.field.string, reply, "入力欄も変わらない")
  }

  /// 本文が主なら、同じキーと右クリックの貼り付けは本文に効く（入力欄は変わらない）。
  func testEditingKeysAndTheContextMenuWorkInTheBody() throws {
    let scene = try scene()
    let reply = scene.thread.field.string
    XCTAssertEqual(scene.surface.primary, .body)
    XCTAssertTrue(try press("a", .command, scene))
    XCTAssertTrue(try press("c", .command, scene))
    XCTAssertEqual(clipboard(scene), Self.source)
    XCTAssertTrue(try press("x", .command, scene))
    XCTAssertEqual(documentText(scene), "")
    XCTAssertTrue(try press("v", .command, scene))
    XCTAssertEqual(documentText(scene), Self.source)
    XCTAssertTrue(try press("z", .command, scene))
    XCTAssertEqual(documentText(scene), "")
    XCTAssertTrue(try press("z", [.command, .shift], scene))
    XCTAssertEqual(documentText(scene), Self.source)
    XCTAssertEqual(try contextMenu(at: nil, choose: #selector(NSText.paste(_:)), scene), true)
    XCTAssertEqual(documentText(scene).count, Self.source.count * 2, "右クリックのペーストは本文に貼る")
    XCTAssertEqual(scene.thread.field.string, reply, "入力欄は変わらない")
  }
}
