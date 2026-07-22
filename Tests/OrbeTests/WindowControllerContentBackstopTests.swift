import XCTest

@testable import Orbe

/// 0タブ workspace の content backstop（`AppShellModel.contentIsEmpty`）の契約を固定する。
///
/// 透過モードでは content の不透明な地を各端末 surface が描くため、surface が1枚も無い0タブでは
/// AppShell が `ChromeTranslucency.baseFill` で埋める必要がある（透過ウィンドウ越しの透け防止）。
/// その要否ゲートが `contentIsEmpty` で、0タブ化で立ち・タブが載ると下がる（二重 veil 回避・冪等）。
///
/// 重要: WindowController の構築は libghostty ランタイムを起動する（GhosttyKit 必須）。
final class WindowControllerContentBackstopTests: XCTestCase {

  private var tempStore: URL!
  override func setUp() {
    super.setUp()
    tempStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-backstop-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tempStore
    SettingsPersistence.fileURLOverride = tempStore.appendingPathExtension("settings")
    AppStatePersistence.fileURLOverride = tempStore.appendingPathExtension("appstate")
  }
  override func tearDown() {
    WorkspacePersistence.fileURLOverride = nil
    SettingsPersistence.fileURLOverride = nil
    AppStatePersistence.fileURLOverride = nil
    try? FileManager.default.removeItem(at: tempStore)
    super.tearDown()
  }

  /// 通常起動（タブあり）では backstop を出さない（surface が地を塗る＝二重 veil 回避）。
  func testTabbedWorkspaceHasNoBackstop() {
    let wc = WindowController()
    XCTAssertFalse(wc.model.contentIsEmpty, "タブありでは backstop を出さない")
  }

  /// 0タブへ切替で backstop が立ち、タブありへ戻ると下がる（両方向・冪等）。
  func testBackstopFollowsTabPresenceBothWays() throws {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)]),
        WorkspaceState(name: "empty", rootPath: "/tmp", activeTab: 0, tabs: []),  // 0タブ（休眠）
      ])
    try JSONEncoder().encode(file).write(to: tempStore)

    let wc = WindowController()
    XCTAssertFalse(wc.model.contentIsEmpty, "復元アクティブ（タブあり）は backstop なし")
    wc.switchWorkspace(to: 1)  // 0タブへ
    XCTAssertTrue(wc.model.contentIsEmpty, "0タブへ切替で backstop が立つ")
    wc.switchWorkspace(to: 0)  // タブありへ戻る
    XCTAssertFalse(wc.model.contentIsEmpty, "タブありへ戻ると backstop が下がる")
  }
}
