import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// ウィンドウ最上層（Z=2）の内蔵ブラウザ統合——`⌘B` の純粋トグル（タブ・0 タブ・ボード・URL 編集中ガード）、
/// 端末寸法不変、workspace 切替・overlay 往復・背景タブ閉鎖での状態と焦点の保持、下層遷移命令での
/// 全面閉鎖／右シート維持、および 3 層 `⌥` 単層めくり・`visibleTab`／`done` 通知制御を実窓で守る。
///
/// 壊れると何が起きるか。ブラウザ開閉で端末の行桁が崩れて pty に SIGWINCH が飛ぶ。
/// 0 タブやボード上で `⌘B` が効かなくなる。URL 欄編集中に `⌘T` 等が暴発する。
/// workspace 切替やパレット往復でブラウザが閉じたり焦点が背後の端末へ奪われたりする。
/// 全面ブラウザ上の `⌘E` や `open_file` でブラウザが閉じずゴースト入力になる。
/// 3 層並走時の `⌥` 長押しで下のエディターまで一緒に透ける、または全面ブラウザで覆われた端末の
/// 完了通知（`done`）が届かない・見えた後に消えない。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerBrowserTests: OrbeTestCase {
  override func setUp() {
    super.setUp()
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  static let plain = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)

  func restore(_ workspaces: [WorkspaceState], window: OrbeWindowFake = OrbeWindowFake()) throws
    -> WindowController
  {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0, workspaces: workspaces)
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController(window: window)
    wc.browserView.reduceMotion = true
    return wc
  }

  func layout(_ wc: WindowController) {
    wc.window.contentView?.layoutSubtreeIfNeeded()
  }

  func reportDone(_ wc: WindowController, _ tab: TerminalTab) {
    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "done", sessionId: nil, message: AgentMessage(text: "d")))
  }

  // MARK: - ⌘B トグル・端末寸法不変・0 タブ・ボード・URL 編集中ガード

  /// `⌘B` はタブ・0 タブ・ボードを問わず開閉し、開閉・幅変更・全面切替の前後で端末の寸法を 1px も変えない。
  /// URL 欄編集中は `⌘B` 以外のタブ不要コマンドを不活性化し、`⌘B` は編集を外因終了して閉じる。
  func testCommandBTogglesAcrossTabsZeroTabsAndBoardWithoutResizingTerminal() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain])],
      window: window)
    window.isKey = true
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    let terminalSize = tab.surface.bounds.size
    XCTAssertGreaterThan(terminalSize.width, 0, "前提: 端末が実サイズを持つ")
    XCTAssertNil(wc.browserView.webView, "起動直後は WKWebView を作らない")

    // ⌘B で右シートを開き、幅変更・全面切替・閉鎖を通じても端末寸法は不変。
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("b")))
    XCTAssertEqual(wc.browserMode, .sheet)
    XCTAssertTrue(wc.browserView.focusIsInside, "開くとブラウザへ焦点が移る")
    layout(wc)
    XCTAssertEqual(tab.surface.bounds.size, terminalSize, "右シート表示で端末寸法が変わらない")

    wc.browserView.setSheetRatio(0.72)
    layout(wc)
    XCTAssertEqual(tab.surface.bounds.size, terminalSize, "幅変更で端末寸法が変わらない")

    wc.setBrowserMode(.full, animated: false)
    layout(wc)
    XCTAssertEqual(tab.surface.bounds.size, terminalSize, "全面切替で端末寸法が変わらない")

    // URL 欄編集中は ⌘T が不活性で暴発せず、⌘B だけ編集を外因終了して閉じる。
    wc.browserView.beginURLEditing()
    XCTAssertFalse(wc.handleWindowKeyCommand(.showWorktreePalette), "URL 編集中は ⌘T を抑止")
    XCTAssertEqual(wc.presentedOverlay, .none)
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("b")))
    XCTAssertEqual(wc.browserMode, .closed)
    XCTAssertFalse(wc.browserView.isEditingURL)
    XCTAssertTrue(wc.window.firstResponder === tab.surface, "閉じると端末へ焦点が戻る")
    layout(wc)
    XCTAssertEqual(tab.surface.bounds.size, terminalSize, "閉じても端末寸法が変わらない")

    // 0 タブ（空状態）でも ⌘B が開閉できる。
    wc.closeTab(tab, origin: .gesture)
    XCTAssertEqual(wc.current.selection, .empty, "前提: 0 タブ空状態")
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("b")))
    XCTAssertEqual(wc.browserMode, .sheet)
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("b")))
    XCTAssertEqual(wc.browserMode, .closed)

    // Home ボード上でも ⌘B が開閉できる。
    wc.switchWorkspace(to: try XCTUnwrap(wc.store.homeIndex))
    XCTAssertEqual(wc.current.selection, .board, "前提: ボード選択中")
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("b")))
    XCTAssertEqual(wc.browserMode, .sheet)
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("b")))
    XCTAssertEqual(wc.browserMode, .closed)
  }

  // MARK: - workspace 切替・overlay・背景タブ閉鎖での保持

  /// workspace 切替・背景タブ閉鎖・overlay 往復でブラウザの開閉・比率・焦点記憶を保持する。
  func testWorkspaceSwitchOverlayAndBackgroundClosePreserveBrowserAndFocus() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(
          name: "a", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain, Self.plain]),
        WorkspaceState(name: "b", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain]),
      ], window: window)
    window.isKey = true
    let wsA = try XCTUnwrap(wc.workspaces.first { $0.name == "a" })
    let wsBIndex = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "b" })
    let backgroundTab = wsA.tabs[1]

    wc.setBrowserMode(.sheet, animated: false)
    wc.browserSheetRatio = 0.65
    wc.browserView.setSheetRatio(0.65)
    XCTAssertTrue(wc.browserView.focusIsInside, "前提: 右シートに焦点")

    // 背景タブ閉鎖でも右シートとブラウザ焦点を保持する。
    wc.closeTab(backgroundTab, origin: .controlAPI)
    XCTAssertEqual(wc.browserMode, .sheet)
    XCTAssertTrue(wc.browserView.focusIsInside)

    // ブラウザ焦点のまま workspace 切替しても右シート・比率・ブラウザ焦点を保持する。
    wc.switchWorkspace(to: wsBIndex)
    XCTAssertEqual(wc.browserMode, .sheet)
    XCTAssertEqual(wc.browserSheetRatio, 0.65, accuracy: 0.001)
    XCTAssertTrue(wc.browserView.focusIsInside, "右シート焦点記憶があればブラウザに焦点を保つ")

    // ヘルプ overlay を開いて閉じてもブラウザへ焦点が戻る。
    wc.showHelp()
    wc.window.makeFirstResponder(nil)
    wc.dismissHelp()
    nextTurn()
    XCTAssertEqual(wc.browserMode, .sheet)
    XCTAssertTrue(wc.browserView.focusIsInside, "overlay 閉鎖でブラウザへ焦点復帰")

    // 下層の端末へ焦点を移してから workspace 切替すると、右シートは保ったまま切替先の端末へ焦点が移る。
    let tabB = try XCTUnwrap(wc.activeTab)
    wc.window.makeFirstResponder(tabB.surface)
    XCTAssertFalse(wc.browserView.focusIsInside)
    wc.switchWorkspace(to: try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "a" }))
    XCTAssertEqual(wc.browserMode, .sheet, "右シートは保持")
    XCTAssertTrue(wc.window.firstResponder === wsA.tabs[0].surface, "下層焦点だったなら切替先端末へ")

    // 全面表示では常にブラウザと焦点を保持する。
    wc.setBrowserMode(.full, animated: false)
    wc.switchWorkspace(to: wsBIndex)
    XCTAssertEqual(wc.browserMode, .full)
    XCTAssertTrue(wc.browserView.focusIsInside)
  }

  // MARK: - 下層へ移る操作での Z=2 引き渡し

  /// 下層へ移る命令（タブ選択・`focus_tab`・`⌘E`・`open_file`・`⌘⇧F`）は、右シートを残して焦点を下層へ譲り、
  /// 全面ブラウザは閉じて下層へ移る。全面時の `⌘E` はエディターが既開でも反転せず開いたまま下層へ渡す。
  func testUnderlayCommandsYieldFullBrowserAndKeepSheet() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain, Self.plain])
      ], window: window)
    window.isKey = true
    let (tab0, tab1) = (wc.current.tabs[0], wc.current.tabs[1])
    let file = try caseFile("sample.txt", "hello")

    // 右シート表示中（ブラウザ焦点）にタブ切替 → 右シートは残り、選択先端末へ焦点が移る。
    wc.setBrowserMode(.sheet, animated: false)
    XCTAssertTrue(wc.browserView.isBrowserFocused)
    wc.select(1)
    XCTAssertEqual(wc.browserMode, .sheet, "右シートは閉じない")
    XCTAssertTrue(wc.window.firstResponder === tab1.surface)
    XCTAssertFalse(wc.browserView.isBrowserFocused, "非焦点見た目へ切り替わる")

    // 右シート表示中に ⌘E → 右シートは残り下層だけエディターへ。
    wc.browserView.focusBrowser()
    wc.toggleEditorFace()
    XCTAssertEqual(wc.browserMode, .sheet)
    XCTAssertTrue(tab1.group.view.isEditorOpen)
    XCTAssertTrue(tab1.group.view.editor.focusIsInside)

    // 全面ブラウザ表示中に、下層が既にエディターでも ⌘E は反転せず全面を閉じてエディターを開く。
    wc.setBrowserMode(.full, animated: false)
    wc.toggleEditorFace()
    XCTAssertEqual(wc.browserMode, .closed, "全面ブラウザが閉じる")
    XCTAssertTrue(tab1.group.view.isEditorOpen, "既にエディターでも反転して閉じない")
    XCTAssertTrue(tab1.group.view.editor.focusIsInside)

    // 全面ブラウザ表示中に、既に同じタブのエディターが開いていても open_file で全面を閉じてエディターへ移る。
    wc.setBrowserMode(.full, animated: false)
    guard case .success = wc.controlOpenFile(tabId: tab1.id, path: file.path) else {
      return XCTFail("open_file は success")
    }
    XCTAssertEqual(wc.browserMode, .closed, "既開タブへの open_file でも全面を閉じる")
    XCTAssertTrue(tab1.group.view.isEditorOpen)
    XCTAssertTrue(tab1.group.view.editor.focusIsInside)

    // 全面ブラウザ表示中に focus_tab → 全面が閉じて対象タブの端末へ。
    wc.setBrowserMode(.full, animated: false)
    guard case .success = wc.controlFocusTab(tabId: tab0.id) else {
      return XCTFail("focus_tab は success")
    }
    XCTAssertEqual(wc.browserMode, .closed)
    XCTAssertFalse(tab0.group.view.isEditorOpen)
    XCTAssertTrue(wc.window.firstResponder === tab0.surface)
  }
}
