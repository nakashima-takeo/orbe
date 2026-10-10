import AppKit
import XCTest

@testable import Orbe

/// 連が持つ面の配置——エディター pane から届くキーの分類、面からの焦点通知、永続状態との往復。
/// 窓に載せず、タブを直接組む。
extension TabGroupTests {
  /// pane を窓に載せて first responder にする（chrome キーの gate は first responder が pane の配下であること）。
  private func hosted(_ tab: TerminalTab) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = tab.group.view
    tab.group.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    window.makeFirstResponder(tab.group.view.editor)
    return window
  }

  /// エディター焦点中、タブ水準のキー（⌘E・⌘W・タブ切替）は window コマンドとして上位へ届く。
  func testEditorPaneForwardsTabLevelKeysAsWindowCommands() {
    let tab = TerminalTab.alone(cwd: "/tmp")
    var received: [WindowCommand] = []
    tab.group.onWindowCommand = { received.append($0) }
    let window = hosted(tab)
    let pane = tab.group.view.editor

    XCTAssertTrue(pane.performKeyEquivalent(with: .key("e")))
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("w")))
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("}", [.command, .shift])))

    XCTAssertEqual(received, [.toggleEditorFace, .closeTab, .nextTab])
    window.orderOut(nil)
  }

  /// 端末固有の chrome キー（フォント）は消費して何も起こさず、両面のキーのうち ⌘F は面が取り（空状態では何も
  /// 起きない）、⌘↑ と通常キーは先取りせずに流す。
  func testEditorPaneSwallowsTerminalOnlyKeysAndPassesSharedKeys() {
    let tab = TerminalTab.alone(cwd: "/tmp")
    var received: [WindowCommand] = []
    tab.group.onWindowCommand = { received.append($0) }
    let window = hosted(tab)
    let pane = tab.group.view.editor

    XCTAssertTrue(pane.performKeyEquivalent(with: .key("f")), "⌘F は面が取る（端末へ届かない）")
    XCTAssertNil(pane.searchBar, "空状態の ⌘F は何も起きない")
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("+")), "⌘+ は消費")
    XCTAssertFalse(
      pane.performKeyEquivalent(
        with: .key(String(UnicodeScalar(NSEvent.SpecialKey.upArrow.rawValue)!))),
      "⌘↑ は両面のキー＝テキスト面へ流す")
    XCTAssertFalse(pane.performKeyEquivalent(with: .key("a", [])), "通常キーは先取りしない")

    XCTAssertEqual(received, [], "window コマンドにはならない")
    window.orderOut(nil)
  }

  /// 端末焦点の ⌘F は端末面のスクロールバック検索バーを開き、エディター面の検索は開かない。
  func testCommandFOnTheTerminalOpensTheScrollbackSearchNotTheEditorSearch() throws {
    let tab = TerminalTab.alone(cwd: "/tmp")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = tab.group.view
    window.makeFirstResponder(tab.surface)

    tab.surface.keyDown(with: .key("f"))

    XCTAssertNotNil(tab.surface.searchBar)
    XCTAssertNil(tab.group.view.editor.searchBar)
    window.orderOut(nil)
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
    window.orderOut(nil)
  }

  /// 面が first responder になった通知は分割中だけ焦点を動かし、配置の変更として上位へ届く。
  /// 全面の配置では隠れた面からの通知が焦点を奪えない（正規形）。
  func testPaneFocusNotificationMovesFocusOnlyWhileSplit() {
    let group = TabGroup(key: "/tmp")
    var changes = 0
    group.onFacesChange = { changes += 1 }

    group.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    group.paneDidFocus(.editor)
    XCTAssertEqual(group.faces, FaceLayout(editorRatio: 0.5, focus: .editor), "分割中は通知した面が焦点")
    XCTAssertEqual(changes, 2)

    group.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    group.paneDidFocus(.terminal)
    XCTAssertEqual(group.faces, FaceLayout(editorRatio: 1, focus: .editor), "隠れた端末は焦点を取れない")
    XCTAssertEqual(changes, 3, "変わらなければ通知しない")
  }

  /// 永続状態は配置を運び、読んだ配置は正規形に直して連に置く。
  func testGroupStateCarriesTheFacesAndRestoreNormalizesThem() {
    let split = FaceLayout(editorRatio: 0.3, focus: .editor)
    let group = TabGroup(key: "/tmp")
    group.setFaces(split, animated: false)
    XCTAssertEqual(group.groupState(), GroupState(root: "/tmp", faces: split))

    let restored = TabGroup(
      key: "/tmp",
      state: GroupState(root: "/tmp", faces: FaceLayout(editorRatio: 1.5, focus: .terminal)))
    XCTAssertEqual(restored.faces, FaceLayout(editorRatio: 1, focus: .editor), "範囲外は正規形へ")
  }
}
