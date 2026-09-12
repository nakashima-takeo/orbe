import AppKit
import XCTest

@testable import Orbe

/// タブが持つ面の配置——エディター pane から届くキーの分類、面からの焦点通知、復元単位との往復。
/// 窓に載せず、タブを直接組む。
extension TerminalTabTests {
  /// pane を窓に載せて first responder にする（chrome キーの gate は first responder が pane の配下であること）。
  private func hosted(_ tab: TerminalTab) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = tab.view
    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    window.makeFirstResponder(tab.view.editor)
    return window
  }

  /// エディター焦点中、タブ水準のキー（⌘E・⌘W・タブ切替）は window コマンドとして上位へ届く。
  func testEditorPaneForwardsTabLevelKeysAsWindowCommands() {
    let tab = TerminalTab(cwd: "/tmp")
    var received: [WindowCommand] = []
    tab.onWindowCommand = { received.append($0) }
    let window = hosted(tab)
    let pane = tab.view.editor

    XCTAssertTrue(pane.performKeyEquivalent(with: .key("e")))
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("w")))
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("}", [.command, .shift])))

    XCTAssertEqual(received, [.toggleEditorFace, .closeTab, .nextTab])
    window.orderOut(nil)
  }

  /// 端末固有の chrome キー（検索・フォント）は消費して何も起こさず、両面のキー（⌘↑）と通常キーは飲まずに
  /// 流す（文書があればテキスト面へ届く。空状態では `keyDown` が飲む）。
  func testEditorPaneSwallowsTerminalOnlyKeysAndPassesSharedKeys() {
    let tab = TerminalTab(cwd: "/tmp")
    var received: [WindowCommand] = []
    tab.onWindowCommand = { received.append($0) }
    let window = hosted(tab)
    let pane = tab.view.editor

    XCTAssertTrue(pane.performKeyEquivalent(with: .key("f")), "⌘F は消費（端末へ届かない）")
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("+")), "⌘+ は消費")
    XCTAssertFalse(
      pane.performKeyEquivalent(
        with: .key(String(UnicodeScalar(NSEvent.SpecialKey.upArrow.rawValue)!))),
      "⌘↑ は両面のキー＝テキスト面へ流す")
    XCTAssertFalse(pane.performKeyEquivalent(with: .key("a", [])), "通常キーは先取りしない")
    pane.keyDown(with: .key("a", []))

    XCTAssertEqual(received, [], "window コマンドにはならない")
    window.orderOut(nil)
  }

  /// first responder が pane の配下に無ければ chrome キーを取らない（隠れたタブの pane が横取りしない）。
  func testEditorPaneIgnoresKeysWhenNotFocused() {
    let tab = TerminalTab(cwd: "/tmp")
    var received: [WindowCommand] = []
    tab.onWindowCommand = { received.append($0) }
    let window = hosted(tab)
    window.makeFirstResponder(nil)

    XCTAssertFalse(tab.view.editor.performKeyEquivalent(with: .key("e")))
    XCTAssertEqual(received, [])
    window.orderOut(nil)
  }

  /// 面が first responder になった通知は分割中だけ焦点を動かし、配置の変更として上位へ届く。
  /// 全面の配置では隠れた面からの通知が焦点を奪えない（正規形）。
  func testPaneFocusNotificationMovesFocusOnlyWhileSplit() {
    let tab = TerminalTab(cwd: "/tmp")
    var changes = 0
    tab.onFacesChange = { changes += 1 }

    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    tab.paneDidFocus(.editor)
    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 0.5, focus: .editor), "分割中は通知した面が焦点")
    XCTAssertEqual(changes, 2)

    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    tab.paneDidFocus(.terminal)
    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 1, focus: .editor), "隠れた端末は焦点を取れない")
    XCTAssertEqual(changes, 3, "変わらなければ通知しない")
  }

  /// 復元単位は配置を運び、読んだ配置は正規形に直してタブに置く。
  func testTabStateCarriesTheFacesAndRestoreNormalizesThem() {
    let split = FaceLayout(editorRatio: 0.3, focus: .editor)
    let tab = TerminalTab(cwd: "/tmp")
    tab.setFaces(split, animated: false)
    XCTAssertEqual(tab.tabState().faces, split)

    let restored = TerminalTab(
      restoring: TabState(
        cwd: "/tmp", agent: nil, explicitTitle: nil,
        faces: FaceLayout(editorRatio: 1.5, focus: .terminal)), resumeSpawn: { _ in nil })
    XCTAssertEqual(restored.faces, FaceLayout(editorRatio: 1, focus: .editor), "範囲外は正規形へ")
  }
}
