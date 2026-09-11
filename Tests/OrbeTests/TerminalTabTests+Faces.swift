import AppKit
import XCTest

@testable import Orbe

/// タブが持つ面の配置——エディター pane から届くキーの分類、面からの焦点通知、復元単位との往復。
/// 窓に載せず、タブを直接組む。
extension TerminalTabTests {
  /// エディター焦点中、タブ水準のキー（⌘E・⌘W・タブ切替）は window コマンドとして上位へ届く。
  func testEditorPaneForwardsTabLevelKeysAsWindowCommands() {
    let tab = TerminalTab(cwd: "/tmp")
    var received: [WindowCommand] = []
    tab.onWindowCommand = { received.append($0) }
    let pane = tab.view.editor

    pane.keyDown(with: .key("e"))
    pane.keyDown(with: .key("w"))
    pane.keyDown(with: .key("}", [.command, .shift]))

    XCTAssertEqual(received, [.toggleEditorFace, .closeTab, .nextTab])
  }

  /// 端末固有の chrome キー（検索・スクロール・フォント）と通常キーは、エディター pane が飲んで何も起こさない。
  func testEditorPaneSwallowsTerminalOnlyKeys() {
    let tab = TerminalTab(cwd: "/tmp")
    var received: [WindowCommand] = []
    tab.onWindowCommand = { received.append($0) }
    let pane = tab.view.editor

    pane.keyDown(with: .key("f"))
    pane.keyDown(with: .key(String(UnicodeScalar(NSEvent.SpecialKey.upArrow.rawValue)!)))
    pane.keyDown(with: .key("+"))
    pane.keyDown(with: .key("a", []))

    XCTAssertEqual(received, [], "window コマンドにはならない")
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
