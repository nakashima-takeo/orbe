import AppKit
import XCTest

@testable import Orbe

/// chrome キーマップ（Orbe が先取りし surface へ転送しない操作）の単一ソースを守る。
/// libghostty 非依存。NSEvent をモックして全分岐を固定する。
final class KeybindingsTests: XCTestCase {
  private func key(_ chars: String, _ flags: NSEvent.ModifierFlags = .command) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: 0, windowNumber: 0, context: nil,
      characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!
  }

  /// 矢印キーは specialKey の unicode（charactersIgnoringModifiers）から判定されるため、その文字で生成する。
  private func arrow(_ k: NSEvent.SpecialKey, _ flags: NSEvent.ModifierFlags = .command) -> NSEvent
  {
    key(String(UnicodeScalar(k.rawValue)!), flags)
  }

  func testFontSize() {
    XCTAssertEqual(Keybindings.chromeAction(for: key("=")), .increaseFontSize)
    XCTAssertEqual(Keybindings.chromeAction(for: key("+")), .increaseFontSize)
    XCTAssertEqual(Keybindings.chromeAction(for: key("-")), .decreaseFontSize)
    XCTAssertEqual(Keybindings.chromeAction(for: key("0")), .resetFontSize)
  }

  func testSplitAndClose() {
    XCTAssertEqual(Keybindings.chromeAction(for: key("d")), .splitRight)
    XCTAssertEqual(Keybindings.chromeAction(for: key("D", [.command, .shift])), .splitDown)
    XCTAssertEqual(Keybindings.chromeAction(for: key("w")), .closePane)
  }

  func testTabsAndFind() {
    XCTAssertEqual(Keybindings.chromeAction(for: key("t")), .newTab)
    XCTAssertEqual(Keybindings.chromeAction(for: key("}", [.command, .shift])), .nextTab)
    XCTAssertEqual(Keybindings.chromeAction(for: key("{", [.command, .shift])), .prevTab)
    // 矢印は別名として次/前タブに割当（Cmd+Shift+→ / Cmd+Shift+←）。
    XCTAssertEqual(Keybindings.chromeAction(for: arrow(.rightArrow, [.command, .shift])), .nextTab)
    XCTAssertEqual(Keybindings.chromeAction(for: arrow(.leftArrow, [.command, .shift])), .prevTab)
    // Shift なしの Cmd+→ / Cmd+← は奪わない（行末・行頭移動として surface へ通す）。
    XCTAssertNil(Keybindings.chromeAction(for: arrow(.rightArrow)))
    XCTAssertNil(Keybindings.chromeAction(for: arrow(.leftArrow)))
    XCTAssertEqual(Keybindings.chromeAction(for: key("f")), .find)
  }

  func testScrollJump() {
    // Shift なしの Cmd+↑ / Cmd+↓ でスクロールバックの先頭・末尾へジャンプ。
    XCTAssertEqual(Keybindings.chromeAction(for: arrow(.upArrow)), .scrollToTop)
    XCTAssertEqual(Keybindings.chromeAction(for: arrow(.downArrow)), .scrollToBottom)
    // Cmd+Shift+↑/↓ は ToolRail の上下切替（prevTool/nextTool）に割当。
    XCTAssertEqual(Keybindings.chromeAction(for: arrow(.upArrow, [.command, .shift])), .prevTool)
    XCTAssertEqual(Keybindings.chromeAction(for: arrow(.downArrow, [.command, .shift])), .nextTool)
  }

  func testWorkspacePalette() {
    XCTAssertEqual(Keybindings.chromeAction(for: key("S", [.command, .shift])), .switchWorkspace)
    // Cmd+N（Shift なし）は作成フォームを開く。
    XCTAssertEqual(Keybindings.chromeAction(for: key("n")), .newWorkspace)
    // Opt/Ctrl 併用は奪わない。
    XCTAssertNil(Keybindings.chromeAction(for: key("n", [.command, .option])))
  }

  func testEditorPaneToggle() {
    XCTAssertEqual(Keybindings.chromeAction(for: key("/")), .toggleEditorPane)  // Cmd+/
    XCTAssertNil(Keybindings.chromeAction(for: key("/", [.command, .option])))
  }

  func testShowSettings() {
    XCTAssertEqual(Keybindings.chromeAction(for: key(",")), .showSettings)  // Cmd+,
    // Opt/Ctrl 併用は奪わない。
    XCTAssertNil(Keybindings.chromeAction(for: key(",", [.command, .option])))
  }

  func testAgentShortcuts() {
    XCTAssertEqual(Keybindings.chromeAction(for: key("A", [.command, .shift])), .showAgentPalette)
    XCTAssertEqual(
      Keybindings.chromeAction(for: key("C", [.command, .shift])), .launchDefaultAgent)
    // Shift なしの Cmd+A / Cmd+C（全選択・コピー系）は奪わない。
    XCTAssertNil(Keybindings.chromeAction(for: key("a")))
    XCTAssertNil(Keybindings.chromeAction(for: key("c")))
  }

  func testDispatchPalette() {
    XCTAssertEqual(
      Keybindings.chromeAction(for: key("X", [.command, .shift])), .showDispatchPalette)
    // Shift なしの Cmd+X（切り取り系）は奪わない。
    XCTAssertNil(Keybindings.chromeAction(for: key("x")))
  }

  /// ChromeHostingView は window レベルで pane 非依存 window コマンド（availableWithoutTabs）だけを
  /// 横取りし、surface 操作系（⌘W closePane）や content 依存コマンド（⌘/ toggleEditorPane）は
  /// 素通しする（0タブでも pane 非依存キーが届き、他は surface 経由 no-op のまま、の切り分けの機構部分）。
  /// libghostty 非依存（surface を作らず AppShell の SwiftUI ルートだけ構築する）。
  func testChromeHostingViewInterceptsPaneIndependentCommandsOnly() {
    let model = AppShellModel(statusModel: StatusRowModel(), content: NSView())
    let view = ChromeHostingView(
      rootView: AppShell(
        model: model, translucency: ChromeTranslucency(), agentIconResolver: AgentIconResolver(),
        fontResolver: ChromeFontResolver(), localization: LocalizationStore(language: .en)))
    var handled: [TerminalController.WindowCommand] = []
    view.onWindowCommand = { command in
      handled.append(command)
      return true
    }

    XCTAssertTrue(view.performKeyEquivalent(with: key("t")), "⌘T（newTab）は横取りして処理する")
    XCTAssertEqual(handled, [.newTab], "⌘T でハンドラが .newTab で1回呼ばれる")

    _ = view.performKeyEquivalent(with: key("w"))
    XCTAssertEqual(handled, [.newTab], "⌘W（closePane・surface 操作系）は横取りせずハンドラを呼ばない")

    _ = view.performKeyEquivalent(with: key("/"))
    XCTAssertEqual(
      handled, [.newTab], "⌘/（toggleEditorPane・content 依存）は横取りせず EditorPane/subtree へ流す")
  }

  /// `ChromeAction.windowCommand`（surface 経路・window レベル経路が共有する単一ソース mapping）を網羅固定する。
  /// window 系14アクションは対応する WindowCommand へ、surface ローカル9アクションは nil へ写す。
  /// この分類が回帰すると 0タブ配信の可否（availableWithoutTabs）とキー振り分け全体がズレる。
  func testWindowCommandMappingIsExhaustive() {
    let mapped: [(ChromeAction, TerminalController.WindowCommand)] = [
      (.newTab, .newTab),
      (.nextTab, .nextTab),
      (.prevTab, .prevTab),
      (.prevTool, .prevTool),
      (.nextTool, .nextTool),
      (.switchWorkspace, .switchWorkspace),
      (.newWorkspace, .newWorkspace),
      (.toggleEditorPane, .toggleEditorPane),
      (.launchDefaultAgent, .launchDefaultAgent),
      (.showAgentPalette, .showAgentPalette),
      (.showDispatchPalette, .showDispatchPalette),
      (.openEditor, .openEditor),
      (.rename, .renameTab),
      (.showSettings, .showSettings),
    ]
    for (action, command) in mapped {
      XCTAssertEqual(action.windowCommand, command, "\(action) は window コマンド \(command) へ写す")
    }
    // surface ローカル操作（WindowController へ届けない）は nil。
    let surfaceLocal: [ChromeAction] = [
      .increaseFontSize, .decreaseFontSize, .resetFontSize,
      .splitRight, .splitDown, .closePane, .find,
      .scrollToTop, .scrollToBottom,
    ]
    for action in surfaceLocal {
      XCTAssertNil(action.windowCommand, "\(action) は surface ローカルゆえ windowCommand は nil")
    }
  }

  /// `WindowCommand.availableWithoutTabs`（0タブでも window レベルで配信してよいか）の分類を網羅固定する。
  /// pane 非依存7コマンドのみ true、content/エディタ依存7コマンドは false。この分類が回帰すると
  /// 0タブで効くべきキーが死ぬ／効くべきでない content 依存キーが暴発する。
  func testAvailableWithoutTabsClassification() {
    let available: [TerminalController.WindowCommand] = [
      .newTab, .newWorkspace, .switchWorkspace,
      .launchDefaultAgent, .showAgentPalette, .showDispatchPalette, .showSettings,
    ]
    for command in available {
      XCTAssertTrue(command.availableWithoutTabs, "\(command) は pane 非依存ゆえ 0タブでも配信する")
    }
    let requiresTabs: [TerminalController.WindowCommand] = [
      .nextTab, .prevTab, .prevTool, .nextTool,
      .toggleEditorPane, .openEditor, .renameTab,
    ]
    for command in requiresTabs {
      XCTAssertFalse(
        command.availableWithoutTabs, "\(command) は content/エディタ依存ゆえ 0タブでは配信しない")
    }
  }

  func testNonChromeKeysPassThrough() {
    // Command 修飾が無ければ chrome は先取りしない（surface へ転送される）。
    XCTAssertNil(Keybindings.chromeAction(for: key("d", [])))
    XCTAssertNil(Keybindings.chromeAction(for: key("a", [.control])))
    // 未割当の Command キーも先取りしない。
    XCTAssertNil(Keybindings.chromeAction(for: key("x")))
    // Opt/Ctrl 併用も先取りしない（surface 側の super+alt 系 keybind を遮蔽しない）。
    XCTAssertNil(Keybindings.chromeAction(for: key("d", [.command, .option])))
    XCTAssertNil(Keybindings.chromeAction(for: key("f", [.command, .control])))
  }
}
