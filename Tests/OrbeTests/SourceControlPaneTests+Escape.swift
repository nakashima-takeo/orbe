import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// esc の知らせを持たないメッセージ欄（ソース管理のメッセージ欄）の esc——欄は esc の命令を取らず、例外も出さずに、次の
/// responder（最後は窓）へ渡す。欄のフォーカスと文は変わらない。
///
/// 壊れると何が起きるか。メッセージ欄で esc を押すと例外が出る。esc の命令が欄で止まり、上の responder が esc を受けない。
extension SourceControlPaneTests {
  /// esc の命令が届いた回数を数える窓。
  private final class EscapeCountingWindow: NSWindow {
    var escapes = 0

    override func cancelOperation(_ sender: Any?) { escapes += 1 }
  }

  /// メッセージ欄で esc を押すと、esc の命令は窓まで渡る。欄のフォーカスと打った文は残る。
  func testEscapeInTheMessageGoesOnToTheWindow() throws {
    let repo = try TempGitRepo()
    let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    let window = EscapeCountingWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = pane
    pane.layoutSubtreeIfNeeded()
    holdUntilTestEnds(window)
    pane.switchScreen(.changes)
    pumpMain(until: { self.messageField(in: pane) != nil }, "メッセージ欄")
    let field = try XCTUnwrap(messageField(in: pane))
    XCTAssertNil(field.onEscape, "前提: esc の知らせを持たない欄")
    window.makeFirstResponder(field)
    field.insertText("fix", replacementRange: NSRange(location: NSNotFound, length: 0))

    let escape = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: 53))
    deliverKeyDown(escape, to: window)
    XCTAssertEqual(window.escapes, 1, "esc の命令は窓まで渡る")
    XCTAssertTrue(window.firstResponder === field, "フォーカスは欄に残る")
    XCTAssertEqual(field.string, "fix", "打った文は残る")
  }
}
