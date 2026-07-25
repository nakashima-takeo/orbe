import AppKit
import XCTest

@testable import Orbe

/// ⇧⌘T（直近に閉じたタブを閉じた位置へ戻す）の配線を、実 `WindowController` で端から端まで通す。
///
/// 純ドメイン側の契約——積む/積まない・閉じた index の記録・LIFO・上限——は
/// `SessionStoreClosedTabsTests` が `SessionStore` を直接叩いて固定する。ここが守るのはその外側、
/// つまり「⇧⌘T が閉じた位置・閉じた時の復元単位・そのタブへの切り替えを実際に起こすか」。
/// store の契約がいくら固くても、`restoreClosedTab` が `closed.index` を捨てれば機能は消える。
///
/// 叩くのは 3 枚のうち**中間**のタブ——両端だと「常に先頭へ挿す」「常に末尾へ挿す」実装と区別できず、
/// 閉じた位置が運ばれていることを固定できない（`ChromeMiddleClickTests` が中央タブを叩くのと同じ作法）。
/// 復元単位も既定値と区別できる値（分割ツリー・明示タイトル・EditorPane 開＋git）で仕込む——
/// 全部既定値だと `makeTab` を素の `TerminalController()` に退化させても緑のままになる。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerRestoreClosedTabTests: XCTestCase {

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

  /// 中間タブ "api" だけが非既定の復元単位を持つ 3 タブ workspace を復元する。
  private func restoreThreeTabs() throws -> WindowController {
    try restore([
      TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: "a"),
      TabState(
        tree: .split(
          vertical: true, ratio: 0.4,
          first: .leaf(cwd: nil, agent: nil), second: .leaf(cwd: nil, agent: nil)),
        explicitTitle: "api", editor: EditorPaneTabState(open: true, tool: "git")),
      TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: "c"),
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

  /// main キューに積まれた非同期ブロック（`TerminalController.close` の `onEmpty` ホップ）を捌く。
  /// FIFO なので、close の後に積んだこのブロックが走った時点で `onEmpty` は処理済み。
  private func drainMainQueue() {
    let exp = expectation(description: "main queue drained")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)
  }

  /// ⇧⌘T は、閉じたタブを**閉じた位置**へ、**閉じた時の復元単位**のまま戻し、そのタブへ切り替える。
  /// 位置・状態・選択の 3 点が本機能の観測可能な契約のすべて。
  func testRestoreReopensAtClosedPositionWithStateAndSelectsIt() throws {
    let wc = try restoreThreeTabs()
    XCTAssertEqual(titles(wc), ["a", "api", "c"], "前提: 中間が api")
    XCTAssertEqual(wc.current.active, 0, "前提: 先頭がアクティブ（復元後の active=1 と区別する）")

    wc.statusModel.onCloseTab(1)  // 中間タブを中クリック＝人のジェスチャで閉じる
    XCTAssertEqual(titles(wc), ["a", "c"], "前提: 中間タブが閉じている")

    XCTAssertTrue(
      wc.handleWindowKeyCommand(.restoreClosedTab), "⇧⌘T は window コマンドとして消費される")

    XCTAssertEqual(titles(wc), ["a", "api", "c"], "先頭でも末尾でもなく、閉じた位置へ戻る")
    let restored = wc.current.tabs[1]
    guard case .split(let vertical, _, _, _) = restored.snapshot() else {
      return XCTFail("分割ツリーごと戻る（素の新規タブに退化していない）")
    }
    XCTAssertTrue(vertical, "分割の向きも復元単位に載って戻る")
    XCTAssertTrue(restored.editorUI.paneOpen, "EditorPane の開閉も戻る")
    XCTAssertEqual(restored.editorUI.tool, .git, "開いていたツールも戻る")
    XCTAssertEqual(wc.current.active, 1, "戻したタブへ切り替わる（既存のタブ生成系と同じく見せる）")
  }

  /// 最後の 1 枚を閉じて 0タブになった workspace へも戻せる。
  /// `availableWithoutTabs` に `.restoreClosedTab` を入れたことが効く経路——ここが死ぬと
  /// 「うっかり最後のタブを閉じた」という本機能の主用途が成立しない。
  func testRestoreRevivesEmptiedWorkspace() throws {
    let wc = try restore([TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: "only")])

    wc.statusModel.onCloseTab(0)
    XCTAssertTrue(wc.current.tabs.isEmpty, "前提: 0タブ（休眠）workspace")

    XCTAssertTrue(wc.handleWindowKeyCommand(.restoreClosedTab))

    XCTAssertEqual(titles(wc), ["only"], "0タブからも復活する")
    XCTAssertEqual(wc.current.active, 0, "唯一のタブを指す")
  }

  /// 何も閉じていなければ ⇧⌘T は無反応（音もダイアログも出さず、タブ集合も選択も動かない）。
  func testRestoreWithEmptyStackChangesNothing() throws {
    let wc = try restoreThreeTabs()
    let before = titles(wc)

    XCTAssertTrue(wc.handleWindowKeyCommand(.restoreClosedTab), "キーは常に消費する（⌘T と同じ）")

    XCTAssertEqual(titles(wc), before, "スタックが空ならタブは増えない")
    XCTAssertEqual(wc.current.active, 0, "選択も動かない")
  }

  /// シェル exit・エージェント終了（`.process`）で落ちたタブは戻せない。
  /// 実経路（`close` → main へ async → `onEmpty` → `closeTab` → `removeTab`）を丸ごと通す——
  /// `wire` が origin を素通しせず決め打ちすると、この非同期ホップの先でだけ嘘になる。
  func testProcessClosedTabIsNotRestorable() throws {
    let wc = try restoreThreeTabs()
    let victim = wc.current.tabs[0]  // 単一ペインの葉タブ（close がそのままタブ閉鎖へカスケードする）

    // close_surface_cb（シェル exit）と同じ呼び方。
    victim.close(try XCTUnwrap(victim.focusedPane), origin: .process)
    drainMainQueue()

    XCTAssertEqual(titles(wc), ["api", "c"], "前提: 先頭タブが落ちている")
    XCTAssertTrue(wc.current.closedTabs.isEmpty, "プロセス終了で落ちたタブは積まない")

    XCTAssertTrue(wc.handleWindowKeyCommand(.restoreClosedTab))

    XCTAssertEqual(titles(wc), ["api", "c"], "プロセス終了で落ちたタブは ⇧⌘T で戻らない")
  }
}
