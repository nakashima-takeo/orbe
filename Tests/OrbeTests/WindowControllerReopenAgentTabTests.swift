import AppKit
import GhosttyKit
import XCTest

@testable import Orbe

/// ⇧⌘T（最後に閉じたエージェントタブを閉じた位置へ開き直す）の配線を、実 `WindowController` で
/// 端から端まで通す。
///
/// 純ドメイン側の契約——積む/積まない・閉じた index の記録・LIFO・上限——は
/// `SessionStoreClosedAgentTabsTests` が `SessionStore` を直接叩いて固定する。ここが守るのはその外側、
/// つまり「⇧⌘T が閉じた位置・閉じた時の復元単位・そのタブへの切り替えを実際に起こすか」。
/// store の契約がいくら固くても、`reopenClosedAgentTab` が `closed.index` を捨てれば機能は消える。
///
/// 叩くのは 3 枚のうち**中間**のタブ——両端だと「常に先頭へ挿す」「常に末尾へ挿す」実装と区別できず、
/// 閉じた位置が運ばれていることを固定できない（`ChromeMiddleClickTests` が中央タブを叩くのと同じ作法）。
/// 復元単位も既定値と区別できる値（エージェント＋素のシェルの分割・明示タイトル・EditorPane 開＋git）で
/// 仕込む——全部既定値だと `makeTab` を素の `TerminalController()` に退化させても緑のままになる。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerReopenAgentTabTests: XCTestCase {

  // 永続を実 Application Support から隔離する（テストごとに未作成の一時ファイルを指す）。
  private var tempStore: URL!
  override func setUp() {
    super.setUp()
    tempStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-test-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tempStore
    SettingsPersistence.fileURLOverride = tempStore.appendingPathExtension("settings")
    AppStatePersistence.fileURLOverride = tempStore.appendingPathExtension("appstate")
    // 言語確定済み（returning user）として起動し、初回言語選択 overlay で window コマンドが
    // 不活性化されないようにする（handleWindowKeyCommand の overlay ガード）。
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }
  override func tearDown() {
    WorkspacePersistence.fileURLOverride = nil
    SettingsPersistence.fileURLOverride = nil
    AppStatePersistence.fileURLOverride = nil
    try? FileManager.default.removeItem(at: tempStore)
    super.tearDown()
  }

  /// 3 タブ: [0] 素のシェル "a"（アクティブ）/ [1] エージェント＋素のシェルの分割 "api" /
  /// [2] エージェント 1 枚 "c"。エージェントの有無で積む/積まないが分かれる 3 種を 1 つの
  /// workspace に揃える。
  private func restoreThreeTabs() throws -> WindowController {
    try restore([
      TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: "a"),
      TabState(
        tree: .split(
          vertical: true, ratio: 0.4,
          first: .leaf(
            cwd: "/work/api", agent: AgentSession(command: "claude", sessionId: "api-1")),
          second: .leaf(cwd: "/work/web", agent: nil)),
        explicitTitle: "api", editor: EditorPaneTabState(open: true, tool: "git")),
      TabState(
        tree: .leaf(cwd: nil, agent: AgentSession(command: "claude", sessionId: "c-1")),
        explicitTitle: "c"),
    ])
  }

  /// ディスクへ 1 workspace を書いてから復元済み WindowController を返す。
  private func restore(_ tabs: [TabState]) throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: tabs)
      ])
    try JSONEncoder().encode(file).write(to: tempStore)
    return WindowController()
  }

  private func titles(_ wc: WindowController) -> [String?] {
    wc.current.tabs.map(\.explicitTitle)
  }

  /// エージェント hook のセッション報告（制御 API `report_agent`）と同じく、生きたペインへ
  /// エージェントを載せる。
  private func markAsAgent(_ tc: TerminalController) throws {
    let pane = try XCTUnwrap(tc.focusedPane)
    pane.agentCommand = "claude"
    pane.agentSessionId = "live-1"
  }

  /// main キューに積まれた非同期ブロック（`TerminalController.close` の `onEmpty` ホップ）を捌く。
  /// FIFO なので、close の後に積んだこのブロックが走った時点で `onEmpty` は処理済み。
  private func drainMainQueue() {
    let exp = expectation(description: "main queue drained")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)
  }

  /// ⇧⌘T は、閉じたエージェントタブを**閉じた位置**へ、**閉じた時の復元単位**のまま戻し、そのタブへ
  /// 切り替える。位置・状態・選択の 3 点が本機能の観測可能な契約のすべて。
  /// 同居していた素のシェルペインも分割ツリーごと戻る（ゲートは積む対象にだけ効き、戻す中身は削らない）。
  func testReopenRestoresAtClosedPositionWithStateAndSelectsIt() throws {
    let wc = try restoreThreeTabs()
    XCTAssertEqual(titles(wc), ["a", "api", "c"], "前提: 中間が api")
    XCTAssertEqual(wc.current.active, 0, "前提: 先頭がアクティブ（復元後の active=1 と区別する）")

    wc.statusModel.onCloseTab(1)  // 中間タブを中クリック＝人のジェスチャで閉じる
    XCTAssertEqual(titles(wc), ["a", "c"], "前提: 中間タブが閉じている")

    XCTAssertTrue(
      wc.handleWindowKeyCommand(.reopenClosedAgentTab), "⇧⌘T は window コマンドとして消費される")

    XCTAssertEqual(titles(wc), ["a", "api", "c"], "先頭でも末尾でもなく、閉じた位置へ戻る")
    let restored = wc.current.tabs[1]
    guard case .split(let vertical, _, let first, let second) = restored.snapshot() else {
      return XCTFail("分割ツリーごと戻る（素の新規タブに退化していない）")
    }
    XCTAssertTrue(vertical, "分割の向きも復元単位に載って戻る")
    guard case .leaf(_, let agent) = first else { return XCTFail("エージェント側の葉が残る") }
    XCTAssertEqual(
      agent, AgentSession(command: "claude", sessionId: "api-1"), "エージェントはセッションごと戻る")
    XCTAssertEqual(
      second, .leaf(cwd: "/work/web", agent: nil), "同居していた素のシェルペインも cwd ごと戻る")
    XCTAssertTrue(restored.editorUI.paneOpen, "EditorPane の開閉も戻る")
    XCTAssertEqual(restored.editorUI.tool, .git, "開いていたツールも戻る")
    XCTAssertEqual(wc.current.active, 1, "戻したタブへ切り替わる（既存のタブ生成系と同じく見せる）")
  }

  /// エージェントを持たない素のシェルタブは、人のジェスチャで閉じても ⇧⌘T で戻らない。
  /// 戻してもプロセスもスクロールバックも戻らない＝開き直す対象ではない。
  func testGestureClosedPlainShellTabIsNotReopenable() throws {
    let wc = try restoreThreeTabs()

    wc.statusModel.onCloseTab(0)  // 素のシェルタブ "a" を中クリックで閉じる

    XCTAssertEqual(titles(wc), ["api", "c"], "前提: 素のシェルタブが閉じている")
    XCTAssertTrue(wc.current.closedAgentTabs.isEmpty, "素のシェルタブは開き直しスタックへ積まない")

    XCTAssertTrue(wc.handleWindowKeyCommand(.reopenClosedAgentTab), "キーは常に消費する（⌘T と同じ）")

    XCTAssertEqual(titles(wc), ["api", "c"], "素のシェルタブは ⇧⌘T で戻らない")
  }

  /// 最後の 1 枚を閉じて 0タブになった workspace へも戻せる。
  /// `availableWithoutTabs` に `.reopenClosedAgentTab` を入れたことが効く経路——ここが死ぬと
  /// 「うっかり最後のタブを閉じた」という本機能の主用途が成立しない。
  func testReopenRevivesEmptiedWorkspace() throws {
    let wc = try restore([TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: "only")])
    try markAsAgent(wc.current.tabs[0])

    wc.statusModel.onCloseTab(0)
    XCTAssertTrue(wc.current.tabs.isEmpty, "前提: 0タブ（休眠）workspace")

    XCTAssertTrue(wc.handleWindowKeyCommand(.reopenClosedAgentTab))

    XCTAssertEqual(titles(wc), ["only"], "0タブからも復活する")
    XCTAssertEqual(wc.current.active, 0, "唯一のタブを指す")
  }

  /// 何も閉じていなければ ⇧⌘T は無反応（音もダイアログも出さず、タブ集合も選択も動かない）。
  func testReopenWithEmptyStackChangesNothing() throws {
    let wc = try restoreThreeTabs()
    let before = titles(wc)

    XCTAssertTrue(wc.handleWindowKeyCommand(.reopenClosedAgentTab), "キーは常に消費する（⌘T と同じ）")

    XCTAssertEqual(titles(wc), before, "スタックが空ならタブは増えない")
    XCTAssertEqual(wc.current.active, 0, "選択も動かない")
  }

  /// シェル exit・エージェント終了で落ちたエージェントタブは戻せない。
  /// libghostty の継ぎ目（`close_surface_cb`）から実経路を丸ごと通す——`ghostty_surface_request_close`
  /// は shell の exit と同じ入口で、Orbe が登録した callback をその場で呼ぶ。callback が渡す発火源が
  /// `.gesture` に化ければ「`exit` したタブが ⇧⌘T で復活する」が起きるが、`close` を直接叩くテストでは
  /// callback 自身を踏まないため気づけない。この先の
  /// `close` → main へ async → `onEmpty` → `closeTab` → `removeTab` も同時に通る。
  /// エージェントを載せた生きたペインで叩く＝エージェント判定では通る＝発火源の判定だけが効く。
  func testProcessClosedAgentTabIsNotReopenable() throws {
    let wc = try restoreThreeTabs()
    let victim = wc.current.tabs[0]  // 単一ペインの葉タブ（close がそのままタブ閉鎖へカスケードする）
    try markAsAgent(victim)

    let surface = try XCTUnwrap(victim.focusedPane?.surfacePtr, "前提: surface 生成済みのペイン")
    ghostty_surface_request_close(surface)
    drainMainQueue()  // close_surface_cb → close
    drainMainQueue()  // close → onEmpty → closeTab

    XCTAssertEqual(titles(wc), ["api", "c"], "前提: 先頭タブが落ちている")
    XCTAssertTrue(wc.current.closedAgentTabs.isEmpty, "プロセス終了で落ちたタブは積まない")

    XCTAssertTrue(wc.handleWindowKeyCommand(.reopenClosedAgentTab))

    XCTAssertEqual(titles(wc), ["api", "c"], "プロセス終了で落ちたタブは ⇧⌘T で戻らない")
  }
}
