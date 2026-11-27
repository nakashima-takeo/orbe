import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// ウィンドウ最上層（Z=2）の内蔵ブラウザ統合——`⌘B` の純粋トグル（タブ・0 タブ・ボード・URL 編集中ガード）、
/// 端末寸法不変、workspace 切替・overlay 往復・背景タブ閉鎖での状態と焦点の保持、下層遷移命令での
/// 全面閉鎖／右シート維持、3 層 `⌥` 単層めくり、`visibleTab`／`done` 通知制御、Home ボード自動化通知の
/// ブラウザ覆い判定とクリック時閉鎖、および URL 編集中フォーカス保護・タブ改名クリックを実窓で守る。
///
/// 壊れると何が起きるか。ブラウザ開閉で端末の行桁が崩れて pty に SIGWINCH が飛ぶ。
/// 0 タブやボード上で `⌘B` が効かなくなる。URL 欄編集中に下層パレット等が暴発する、または背景操作・タブ改名欄の
/// blur で入力中の URL やブラウザ焦点が奪われる。
/// workspace 切替やパレット往復でブラウザが閉じたり焦点が背後の端末へ奪われたりする。
/// 全面ブラウザ上の `⌘E` や `open_file` でブラウザが閉じずゴースト入力になる。
/// 3 層並走時の `⌥` 長押しで下のエディターまで一緒に透ける、全面ブラウザで覆われた端末の完了通知（`done`）が
/// 届かない・見えた後に消えない、あるいは自動化通知をクリックしても右シートが残って詳細欄が隠れたままになる。
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
  /// URL 欄編集中は単一降下ゲート経由のタブ不要コマンドを不活性化し、`⌘B` は編集を外因終了して閉じる。
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
    XCTAssertEqual(wc.browserView.sheetRatio, 0.72, accuracy: 0.001, "全面切替で比率が巻き戻らない")
    wc.setBrowserMode(.sheet, animated: false)
    XCTAssertEqual(wc.browserView.sheetRatio, 0.72, accuracy: 0.001, "右シート復帰後も設定比率を保つ")
    wc.setBrowserMode(.full, animated: false)

    // URL 欄編集中は単一降下ゲート経由の下層パレットコマンドが不活性で暴発せず、⌘B だけ編集を外因終了して閉じる。
    wc.browserView.beginURLEditing()
    XCTAssertFalse(
      wc.handleWindowKeyCommand(.showWorktreePalette),
      "URL 編集中は単一降下ゲート経由の下層コマンドを抑止")
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

  /// 自由スペース表示中のタブ・worktree・workspace 切替・背景タブ閉鎖・overlay 往復でブラウザの開閉・
  /// 比率・表示ページ・焦点記憶を保持する。
  @MainActor
  func testWorkspaceSwitchOverlayAndBackgroundClosePreserveBrowserAndFocus() throws {
    let wt1 = try caseDir("wt1")
    let wt2 = try caseDir("wt2")
    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(
          name: "a", rootPath: wt1, activeTab: 0,
          tabs: [
            TabState(cwd: wt1, agent: nil, explicitTitle: nil),
            TabState(cwd: wt2, agent: nil, explicitTitle: nil),
          ]),
        WorkspaceState(name: "b", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain]),
      ], window: window)
    window.isKey = true
    let wsA = try XCTUnwrap(wc.workspaces.first { $0.name == "a" })
    let wsAIndex = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "a" })
    let wsBIndex = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "b" })
    let freeSpace = try XCTUnwrap(wc.browserSession.store.freeSpaces.first)
    let pageURL = URL(string: "https://docs.orbe.dev/guide")!

    XCTAssertTrue(wc.browserSession.selectSpace(.free(freeSpace.id)))
    wc.setBrowserMode(.sheet, animated: false)
    wc.browserView.setSheetRatio(0.65)
    loadPage(pageURL, in: wc)
    let freeWebView = try XCTUnwrap(wc.browserView.webView)
    XCTAssertTrue(wc.browserView.focusIsInside, "前提: 右シートに焦点")

    // 別 worktree タブへ切り替えても表示ページとシート比率を保持する。
    wc.select(1)
    XCTAssertEqual(wc.browserMode, .sheet)
    XCTAssertTrue(wc.browserView.webView === freeWebView, "同一 WKWebView 実体を維持する")
    XCTAssertEqual(wc.browserView.webView?.url, pageURL)
    XCTAssertEqual(wc.browserView.toolbar.displayURL?.host, "docs.orbe.dev")
    wc.select(0)
    wc.browserView.focusBrowser()

    // 背景タブ閉鎖でも右シート・ページ・ブラウザ焦点を保持する。
    wc.closeTab(wsA.tabs[1], origin: .controlAPI)
    XCTAssertEqual(wc.browserMode, .sheet)
    XCTAssertEqual(wc.browserView.webView?.url, pageURL)
    XCTAssertTrue(wc.browserView.focusIsInside)

    // 自由スペース表示のまま workspace 切替しても右シート・比率・ページ・同一 WKWebView・焦点を保持する。
    wc.switchWorkspace(to: wsBIndex)
    XCTAssertEqual(wc.browserMode, .sheet)
    XCTAssertEqual(wc.browserView.sheetRatio, 0.65, accuracy: 0.001)
    XCTAssertTrue(wc.browserView.webView === freeWebView, "自由スペース切替で WKWebView を再生成しない")
    XCTAssertEqual(wc.browserView.webView?.url, pageURL)
    XCTAssertEqual(wc.browserView.toolbar.displayURL?.path, "/guide")
    XCTAssertTrue(wc.browserView.focusIsInside, "右シート焦点記憶があればブラウザに焦点を保つ")

    // ヘルプ overlay を開いて閉じてもブラウザへ焦点が戻る。
    wc.showHelp()
    wc.window.makeFirstResponder(nil)
    wc.dismissHelp()
    nextTurn()
    XCTAssertEqual(wc.browserMode, .sheet, "overlay 閉鎖後も右シートを保つ")
    XCTAssertTrue(wc.browserView.focusIsInside, "overlay 閉鎖でブラウザへ焦点復帰")

    // 下層の端末へ焦点を移してから workspace 切替すると、自由スペースのページは保ったまま切替先端末へ焦点が移る。
    wc.window.makeFirstResponder(try XCTUnwrap(wc.activeTab).surface)
    wc.switchWorkspace(to: wsAIndex)
    XCTAssertEqual(wc.browserMode, .sheet, "右シートは保持")
    XCTAssertEqual(wc.browserView.webView?.url, pageURL)
    XCTAssertTrue(wc.window.firstResponder === wsA.tabs[0].surface, "下層焦点だったなら切替先端末へ")

    // 全面表示の自由スペースでは常にブラウザ・ページ・焦点を保持する。
    wc.setBrowserMode(.full, animated: false)
    wc.switchWorkspace(to: wsBIndex)
    XCTAssertEqual(wc.browserMode, .full)
    XCTAssertEqual(wc.browserView.webView?.url, pageURL)
    XCTAssertTrue(wc.browserView.focusIsInside)
  }

  /// ローカルスペース表示中は workspace 切替に追従して切替先 workspace の中身と現在 workspace 名へ切り替わり、
  /// アクティブ workspace 改名のみ即時同期し（背景改名では上書きしない）、元の workspace へ戻すと復帰する。
  @MainActor
  func testLocalSpaceFollowsWorkspaceSwitch() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(name: "a", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain]),
        WorkspaceState(name: "b", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain]),
      ], window: window)
    window.isKey = true
    let wsAIndex = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "a" })
    let wsBIndex = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "b" })
    let localPageURL = URL(string: "https://local.orbe.dev/ws-a")!

    wc.setBrowserMode(.full, animated: false)
    XCTAssertEqual(wc.browserSession.store.activeSpaceSelection, .local, "初回選択はローカルスペース")
    XCTAssertEqual(wc.browserSession.store.currentWorkspaceName, "a", "起動時に現在 WS 名を同期")
    loadPage(localPageURL, in: wc)
    XCTAssertEqual(wc.browserView.webView?.url, localPageURL)

    wc.switchWorkspace(to: wsBIndex)
    XCTAssertEqual(wc.browserSession.store.currentWorkspaceName, "b", "WS 切替で現在 WS 名を同期")
    XCTAssertNil(wc.browserView.webView, "wsB のローカルスペースは空画面へ切り替わる")
    XCTAssertNil(wc.browserView.toolbar.displayURL)
    XCTAssertTrue(wc.browserView.focusIsInside, "全面表示の焦点は維持する")

    wc.renameWorkspace(wsBIndex, to: "beta")
    XCTAssertEqual(wc.browserSession.store.currentWorkspaceName, "beta", "アクティブ WS 改名を即時同期")
    wc.renameWorkspace(wsAIndex, to: "alpha")
    XCTAssertEqual(
      wc.browserSession.store.currentWorkspaceName, "beta", "背景 WS 改名では現在 WS 名を上書きしない")

    wc.switchWorkspace(to: wsAIndex)
    XCTAssertEqual(wc.browserSession.store.currentWorkspaceName, "alpha", "復帰先に改名後 WS 名を同期")
    XCTAssertEqual(wc.browserView.webView?.url, localPageURL, "wsA へ戻すと wsA のローカルページへ復帰する")
  }

  private func caseDir(_ name: String) throws -> String {
    let url = TestScratch.caseDir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
  }

  private func loadPage(_ url: URL, in wc: WindowController) {
    var loaded = false
    wc.browserView.onNavigationFinish = { loaded = true }
    wc.browserView.loadHTMLString("<p>guide</p>", baseURL: url)
    pumpMain(until: { loaded }, timeout: 5, "ブラウザページ読み込み完了")
  }

  // MARK: - 下層へ移る操作での Z=2 引き渡し

  /// 下層へ移る通常命令（タブ選択・`⌘E`・`⌘⇧F`・`open_file`）は、右シートを残したまま焦点を下層へ譲る。
  func testUnderlayCommandsKeepSheetAndYieldFocus() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain, Self.plain])
      ], window: window)
    window.isKey = true
    let tab1 = wc.current.tabs[1]
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

    // 下層エディター既開＋右シート＋ブラウザ焦点中の ⌘⇧F / open_file は、右シートを残して同期に焦点を譲る。
    wc.browserView.focusBrowser()
    XCTAssertTrue(wc.browserView.focusIsInside, "前提: 右シートに焦点")
    XCTAssertTrue(wc.browserWasFocused, "前提: ブラウザ焦点記憶が真")
    wc.handleWindowCommand(.findInProject)
    XCTAssertEqual(wc.browserMode, .sheet, "右シートは閉じない")
    XCTAssertFalse(wc.browserView.focusIsInside, "既開エディターへの ⌘⇧F で同期にブラウザから焦点を譲る")
    XCTAssertFalse(wc.browserView.isBrowserFocused)
    XCTAssertFalse(wc.browserWasFocused)
    XCTAssertTrue(tab1.group.view.editor.showsSearchPanel, "検索パネルが開く")

    wc.browserView.focusBrowser()
    guard case .success = wc.controlOpenFile(tabId: tab1.id, path: file.path) else {
      return XCTFail("open_file は success")
    }
    XCTAssertEqual(wc.browserMode, .sheet, "既開エディターへの open_file でも右シートは残す")
    XCTAssertFalse(wc.browserView.focusIsInside, "既開エディターへの open_file でブラウザから焦点を譲る")
    XCTAssertTrue(tab1.group.view.editor.focusIsInside)
  }

  /// 下層へ移る命令（`⌘⇧F`・`⌘E`・`open_file`・`focus_tab`）は全面ブラウザを閉じて下層へ移る。
  /// 全面時の `⌘E` はエディターが既開でも反転せず開いたまま下層へ渡す。
  func testUnderlayCommandsCloseFullBrowser() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain, Self.plain])
      ], window: window)
    window.isKey = true
    let (tab0, tab1) = (wc.current.tabs[0], wc.current.tabs[1])
    let file = try caseFile("sample.txt", "hello")
    wc.select(1)
    wc.toggleEditorFace()

    // 全面ブラウザ表示中に、下層が既にエディターでも ⌘⇧F は全面を閉じて検索パネルを開く。
    tab1.group.view.editor.showExplorer()
    wc.setBrowserMode(.full, animated: false)
    wc.handleWindowCommand(.findInProject)
    XCTAssertEqual(wc.browserMode, .closed, "全面ブラウザ中の ⌘⇧F は全面を閉じる")
    XCTAssertTrue(tab1.group.view.editor.showsSearchPanel, "全面閉鎖後に検索パネルが開く")

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
