import AppKit
import XCTest

@testable import Orbe

/// 連の器の面へ届くキーの分類。窓は持たず、タブを直接組む。
extension TabGroupTests {
  /// pane を窓に載せて first responder にする（chrome キーの gate は first responder が pane の配下であること）。
  @discardableResult
  private func hosted(_ tab: TerminalTab) -> NSWindow {
    let window = OrbeWindowFake(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = tab.group.view
    tab.group.view.show(.editor, animated: false)
    window.makeFirstResponder(tab.group.view.editor)
    return holdUntilTestEnds(window)
  }

  /// エディター焦点中、タブ水準のキー（⌘E・⌘W・タブ切替）は window コマンドとして上位へ届く。
  func testEditorPaneForwardsTabLevelKeysAsWindowCommands() {
    let tab = TerminalTab.alone(cwd: "/tmp")
    var received: [WindowCommand] = []
    tab.group.onWindowCommand = { received.append($0) }
    hosted(tab)
    let pane = tab.group.view.editor

    XCTAssertTrue(pane.performKeyEquivalent(with: .key("e")))
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("w")))
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("}", [.command, .shift])))

    XCTAssertEqual(received, [.toggleEditorFace, .closeTab, .nextTab])
  }

  /// 端末固有の chrome キー（フォント）は消費して何も起こさず、両面のキーのうち ⌘F は面が取り（空状態では何も
  /// 起きない）、⌘↑ と通常キーは先取りせずに流す。
  func testEditorPaneSwallowsTerminalOnlyKeysAndPassesSharedKeys() {
    let tab = TerminalTab.alone(cwd: "/tmp")
    var received: [WindowCommand] = []
    tab.group.onWindowCommand = { received.append($0) }
    hosted(tab)
    let pane = tab.group.view.editor

    XCTAssertTrue(pane.performKeyEquivalent(with: .key("f")), "⌘F は面が取る（端末へ届かない）")
    XCTAssertNil(pane.findField.model, "空状態の ⌘F は何も起きない")
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("+")), "⌘+ は消費")
    XCTAssertFalse(
      pane.performKeyEquivalent(
        with: .key(String(UnicodeScalar(NSEvent.SpecialKey.upArrow.rawValue)!))),
      "⌘↑ は両面のキー＝テキスト面へ流す")
    XCTAssertFalse(pane.performKeyEquivalent(with: .key("a", [])), "通常キーは先取りしない")

    XCTAssertEqual(received, [], "window コマンドにはならない")
  }

  /// 端末焦点の ⌘F は端末面のスクロールバック検索バーを開き、エディター面の検索は開かない。
  func testCommandFOnTheTerminalOpensTheScrollbackSearchNotTheEditorSearch() throws {
    let tab = TerminalTab.alone(cwd: "/tmp")
    let window = OrbeWindowFake(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    holdUntilTestEnds(window)
    window.contentView = tab.group.view
    window.makeFirstResponder(tab.surface)

    tab.surface.keyDown(with: .key("f"))

    XCTAssertNotNil(tab.surface.searchBar)
    XCTAssertNil(tab.group.view.editor.findField.model)
  }

  /// first responder が pane の配下に無ければ chrome キーを取らない（隠れた連の pane が横取りしない）。
  func testEditorPaneIgnoresKeysWhenNotFocused() {
    let tab = TerminalTab.alone(cwd: "/tmp")
    var received: [WindowCommand] = []
    tab.group.onWindowCommand = { received.append($0) }
    let window = hosted(tab)
    window.makeFirstResponder(nil)

    XCTAssertFalse(tab.group.view.editor.performKeyEquivalent(with: .key("e")))
    XCTAssertEqual(received, [])
  }
}
