import AppKit
import XCTest

@testable import Orbe

/// 行内の新規作成を本物の入力欄（SwiftUI の TextField）で駆動する——出せば入力欄が焦点を取って打鍵が入り、
/// Enter で作ってファイルなら開いて焦点はテキスト面へ、Esc で取り消して焦点は面の行き先へ、入力欄の外を
/// 押して抜ければ取り消すだけで焦点は引き戻さない（窓へ落ちただけでは取り消さない）。深い行や入力行は
/// 可視位置へ送られる。
///
/// 壊れると何が起きるか。「新規ファイル」を押しても打鍵が 1 文字も入らない（入力欄が焦点を取らない・画面外に
/// 生まれて見えない）。Esc の後に焦点が窓へ落ちて打鍵と ⌘S が死ぬ。端末へ抜けたのに焦点がエディターへ引き戻される。
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
    pumpMain(until: { pane.tree.newEntry == nil }, "別の view へ移れば取り消す")
    let responder = try XCTUnwrap(window.firstResponder as? NSView)
    XCTAssertFalse(responder.isDescendant(of: pane), "抜けた先に焦点が残る（面へ引き戻さない）")

    pane.shell.createFile()
    _ = try inputField(pane, in: window)
    window.makeFirstResponder(nil)
    pumpMain(until: { window.firstResponder === window }, "前提: 焦点が窓へ落ちる")
    pane.sideHost.layoutSubtreeIfNeeded()  // 保留中の SwiftUI 更新を走らせ、onChange(of: focused) を確定させる
    XCTAssertNotNil(pane.tree.newEntry, "窓へ落ちただけ（人の操作ではない）では取り消さない")
    XCTAssertTrue(window.firstResponder === pane, "入力は生かしたまま面が焦点を預かる")

    XCTAssertTrue(window.makeFirstResponder(outsider))
    pumpMain(until: { pane.tree.newEntry == nil }, "預かっている間に面の外へ移れば取り消す")
  }

  /// 入力中に別種の「新規」を押すと、前の入力欄が焦点を手放し、新しい入力行が焦点を取って打鍵が入る。
  func testSwitchingTheKindWhileTypingFocusesTheNewInput() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }

    pane.shell.createFile()
    let first = try inputField(pane, in: window)
    first.insertText("dra", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(pane.tree.newEntry?.name, "dra", "打鍵は状態へ")

    pane.shell.createDirectory()
    XCTAssertTrue(window.firstResponder === pane, "前の入力欄は面へ焦点を手放す")
    let second = try inputField(pane, in: window)
    second.insertText("dir", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(pane.tree.newEntry?.isDirectory, true)
    XCTAssertEqual(pane.tree.newEntry?.name, "dir", "新しい入力行が焦点を取って打鍵が入る")
  }

  /// 焦点が面の外にある状態で入力を出すと面自身が焦点を取る。行が焦点を取る前に入力が落ちれば（同じターンで
  /// すべて折りたたむ）、焦点は面に残らず文書のテキスト面へ移る。
  func testInputEndingBeforeTheRowTakesFocusHandsTheFocusToTheTextSurface() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }
    let document = try tab.editor.open(try caseFile("a.txt", "a"))
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    tab.view.addSubview(outsider)
    XCTAssertTrue(window.makeFirstResponder(outsider))

    pane.shell.createFile()
    XCTAssertTrue(window.firstResponder === pane, "前提: 入力を出す前に面自身が焦点を取る")
    pane.shell.collapseAll()
    XCTAssertNil(pane.tree.newEntry)
    XCTAssertTrue(window.firstResponder === document.surface.responder, "面に残らずテキスト面へ")
  }

  /// 低い窓で深い文書をアクティブにするとツリーがその行まで送り、深い挿し先の入力行も可視位置へ送られて
  /// 焦点を取る。
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
    XCTAssertEqual(scroll.documentVisibleRect.minY, 0, "前提: 先頭に居る")

    pane.shell.open(deep)
    pumpMain(until: { scroll.documentVisibleRect.minY > 0 }, "アクティブにした深い行へ送る")

    scroll.contentView.scroll(to: .zero)  // 先頭へ戻してから出す（送りが起きたことを位置で見る）
    scroll.reflectScrolledClipView(scroll.contentView)
    pane.shell.createFile()
    XCTAssertEqual(pane.tree.newEntry?.directory, "d19", "選択したファイルの親（画面外だった深い場所）に挿す")
    pumpMain(until: { scroll.documentVisibleRect.minY > 0 }, "入力行へ送る")
    _ = try inputField(pane, in: window)
  }
}
