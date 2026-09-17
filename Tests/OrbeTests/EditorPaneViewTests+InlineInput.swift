import AppKit
import XCTest

@testable import Orbe

/// 行内の新規作成を本物の入力欄（SwiftUI の TextField）で駆動する——出せば入力欄が焦点を取って打鍵が入り、
/// Enter で作ってファイルなら開いて焦点はテキスト面へ、Esc で取り消して焦点は面の行き先へ、入力欄の外を
/// 押して抜ければ取り消すだけで焦点は引き戻さない。深い行や入力行は可視位置へ送られる（送られなければ
/// 遅延生成の行は生まれず、焦点も打鍵も宙に浮く）。
///
/// 壊れると何が起きるか。「新規ファイル」を押しても打鍵が 1 文字も入らない（入力欄が焦点を取らない・画面外に
/// 生まれる）。Esc の後に焦点が窓へ落ちて打鍵と ⌘S が死ぬ。端末へ抜けたのに焦点がエディターへ引き戻される。
@MainActor
final class EditorPaneViewInlineInputTests: OrbeTestCase {
  /// 入力欄（field editor）が焦点を取るまで待って返す。
  private func inputField(_ pane: EditorPaneView, in window: NSWindow) throws -> NSTextView {
    pumpMain(
      until: { (window.firstResponder as? NSView)?.isDescendant(of: pane.sideHost) == true },
      "入力欄が焦点を取る")
    return try XCTUnwrap(window.firstResponder as? NSTextView)
  }

  private func escape(in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
  }

  func testTypedNameAndReturnCreateTheFileOpenItAndFocusTheTextSurface() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }
    window.makeFirstResponder(nil)

    pane.shell.createFile()
    let field = try inputField(pane, in: window)
    field.insertText("fresh.txt", replacementRange: NSRange(location: 0, length: 0))
    field.keyDown(with: .key("\r", []))
    pumpMain(until: { pane.tree.newEntry == nil }, "Enter で入力が終わる")

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: dir.appendingPathComponent("fresh.txt").path))
    XCTAssertEqual(pane.document?.url.lastPathComponent, "fresh.txt", "作ったファイルはそのまま開く")
    XCTAssertEqual(pane.tree.selected, "fresh.txt")
    XCTAssertTrue(window.firstResponder === pane.document?.surface.responder, "焦点はテキスト面へ")
    XCTAssertEqual(tab.faces.focus, .editor)
  }

  func testEscapeCancelsTheInputAndReturnsTheFocusToThePane() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }
    let document = try tab.editor.open(try caseFile("a.txt", "a"))

    pane.shell.createDirectory()
    let field = try inputField(pane, in: window)
    field.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
    window.sendEvent(escape(in: window))
    pumpMain(until: { pane.tree.newEntry == nil }, "Esc で取り消す")
    pumpMain(until: { window.firstResponder === document.surface.responder }, "焦点は面の行き先へ")

    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("draft").path))
    XCTAssertTrue(pane.tree.rows.allSatisfy { $0.name != "" }, "入力行は消える")
  }

  /// 入力欄は面の配下なので、入力中も chrome キーは面が先取りして上位へ届き、通常の打鍵は入力欄に入る。
  func testChromeKeysStillWorkWhileTheInputHasTheFocus() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }
    var commands: [WindowCommand] = []
    tab.onWindowCommand = { commands.append($0) }

    pane.shell.createFile()
    let field = try inputField(pane, in: window)
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("e")), "⌘E は面が先取りする")
    XCTAssertEqual(commands, [.toggleEditorFace])
    field.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(field.string, "typed", "通常の打鍵は入力欄に入る")
    XCTAssertNotNil(pane.tree.newEntry, "chrome キーで入力は終わらない")
  }

  /// 入力欄の外（端末）を押して抜ければ取り消しになるが、焦点はそこに居るので面へ引き戻さない。
  func testLeavingTheInputForAnotherViewCancelsWithoutPullingTheFocusBack() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    tab.view.addSubview(outsider)

    pane.shell.createFile()
    _ = try inputField(pane, in: window)
    XCTAssertTrue(window.makeFirstResponder(outsider))
    pumpMain(until: { pane.tree.newEntry == nil }, "焦点を失えば取り消す")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))  // 引き取りの判定は次のターン

    let responder = try XCTUnwrap(window.firstResponder as? NSView)
    XCTAssertFalse(responder.isDescendant(of: pane), "抜けた先に焦点が残る（面へ引き戻さない）")
  }

  /// 低い窓で深い文書をアクティブにするとツリーがその行まで送り、深い挿し先の入力行も可視位置に生まれて
  /// 焦点を取る（行は遅延生成なので、送られなければ行も入力欄も存在しない）。
  func testDeepRowsAndTheInputRowAreScrolledIntoView() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    for index in 0..<20 {
      try FileManager.default.createDirectory(
        at: dir.appendingPathComponent(String(format: "d%02d", index)),
        withIntermediateDirectories: true)
    }
    let deep = try caseFile("d19/deep.txt", "x")
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900, height: 240)
    defer { window.orderOut(nil) }
    let scroll = try XCTUnwrap(scrollView(in: pane.sideHost))
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(scroll.documentVisibleRect.minY, 0, "前提: 先頭に居る")

    pane.shell.open(deep)
    pumpMain(until: { scroll.documentVisibleRect.minY > 0 }, "アクティブにした深い行へ送る")

    pane.shell.createFile()
    XCTAssertEqual(pane.tree.newEntry?.directory, "d19", "選択したファイルの親（画面外だった深い場所）に挿す")
    _ = try inputField(pane, in: window)
  }

  private func scrollView(in view: NSView) -> NSScrollView? {
    for subview in view.subviews {
      if let scroll = subview as? NSScrollView { return scroll }
      if let scroll = scrollView(in: subview) { return scroll }
    }
    return nil
  }
}
