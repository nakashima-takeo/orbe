import AppKit
import OrbeSessionLog
import XCTest

@testable import Orbe

/// `restore_sessions` の実体（`controlRestoreSessions`）を実 `WindowController` で固定する——ログの
/// 復元先を rootPath で照合し、無ければ作り、休眠チケットを足し（同 worktree の連の右端、無ければ末尾）、
/// 選択もアクティブ化もしない。ただし空表示の前面 workspace に足したタブは選んで見せる——壊れると、選んでいるのに
/// 見えないタブが残り、⌘W がそれを閉じる。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerRestoreSessionsTests: OrbeTestCase {
  override func setUp() {
    super.setUp()
    // 言語確定済み（returning user）として起動し、初回言語選択 overlay を出さない（overlay は焦点を渡さない）。
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  /// 前面の `main`（既定はタブ 1 枚）と背景の `bg`（タブ 1 枚）。
  private func restore(mainTabs: Int = 1) throws -> WindowController {
    let plain = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp/main", activeTab: 0,
          tabs: Array(repeating: plain, count: mainTabs)),
        WorkspaceState(name: "bg", rootPath: "/tmp/bg", activeTab: 0, tabs: [plain]),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  private func closed(
    _ id: String, rootPath: String, name: String = "gone", cwd: String = "/tmp/x"
  ) -> SessionEvent {
    // カタログに無い agent 名——戻したタブが起きても、本物の agent を起こさず素のシェルになる。
    SessionEvent(
      ts: Date(), kind: .closed(origin: .process, reason: nil, title: nil),
      workspace: .init(name: name, rootPath: rootPath), cwd: cwd,
      agent: .init(command: "orbe-test-agent", sessionId: id))
  }

  private func results(_ result: Result<Any, ControlError>) throws -> [[String: Any]] {
    try XCTUnwrap((result.get() as? [String: Any])?["results"] as? [[String: Any]])
  }

  func testRestoresIntoTheMatchingWorkspaceWithoutSelectingOrActivating() throws {
    let wc = try restore()
    let selected = try XCTUnwrap(wc.current.selectedTab)
    wc.sessionLog.record(closed("b-1", rootPath: "/tmp/bg", cwd: "/tmp/bg/src"))
    wc.sessionLog.record(closed("m-1", rootPath: "/tmp/main"))

    let rows = try results(wc.controlRestoreSessions(sessionIds: ["b-1", "m-1"]))

    XCTAssertEqual(rows.map { $0["status"] as? String }, ["restored", "restored"])
    XCTAssertEqual(rows[0]["workspaceId"] as? Int, wc.workspaces[1].id)
    let tab = try XCTUnwrap(wc.workspaces[1].tabs.last)
    XCTAssertEqual(rows[0]["tabId"] as? Int, tab.id)
    XCTAssertTrue(tab.isDormant, "休眠チケットのまま（起こさない）")
    XCTAssertEqual(tab.cwd, "/tmp/bg/src")
    XCTAssertEqual(wc.workspaces[1].selectedTabIndex, 0, "背景 WS の選択は動かさない")
    XCTAssertTrue(wc.current.selectedTab === selected, "前面 WS の選択も動かさない")
    XCTAssertEqual(wc.activeWorkspace, 0, "前面化しない")
    XCTAssertEqual(wc.sessionLog.lastEvent(sessionId: "b-1")?.closeOrigin, .process, "復元では書かない")
  }

  /// 空表示の前面 workspace に戻したタブは、選ばれるだけでなく見えて焦点を取る。
  func testRestoringIntoTheEmptyFrontWorkspaceShowsTheTab() throws {
    let wc = try restore(mainTabs: 0)
    XCTAssertTrue(wc.model.contentIsEmpty, "前提: 前面 WS は空表示")
    wc.sessionLog.record(closed("m-1", rootPath: "/tmp/main"))

    _ = try results(wc.controlRestoreSessions(sessionIds: ["m-1"]))

    let tab = try XCTUnwrap(wc.current.tabs.first)
    XCTAssertTrue(wc.current.selectedTab === tab)
    XCTAssertEqual(wc.model.content.subviews.filter { !$0.isHidden }, [tab.view], "そのタブが見える")
    XCTAssertFalse(wc.model.contentIsEmpty, "空表示の地を重ねない")
    XCTAssertTrue(wc.window.firstResponder === tab.surface, "焦点はそのタブ")
  }

  func testCreatesTheWorkspaceFromTheLogWhenNoneMatches() throws {
    let wc = try restore()
    wc.sessionLog.record(closed("n-1", rootPath: "/tmp/new", name: "newws"))

    let rows = try results(wc.controlRestoreSessions(sessionIds: ["n-1"]))

    XCTAssertEqual(wc.regularWorkspaces.count, 3)
    let created = try XCTUnwrap(wc.workspaces.last)
    XCTAssertEqual(created.name, "newws")
    XCTAssertEqual(created.rootPath, "/tmp/new")
    XCTAssertEqual(created.tabs.count, 1)
    XCTAssertEqual(rows[0]["workspaceId"] as? Int, created.id)
    XCTAssertEqual(wc.activeWorkspace, 0, "作った workspace をアクティブ化しない")
  }

  func testStatusesAreIdempotentPerId() throws {
    let wc = try restore()
    wc.sessionLog.record(closed("m-1", rootPath: "/tmp/main"))
    let live = try XCTUnwrap(wc.current.tabs.first)
    live.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "live-1"))

    let rows = try results(
      wc.controlRestoreSessions(sessionIds: ["m-1", "m-1", "live-1", "nope"]))

    XCTAssertEqual(
      rows.map { $0["status"] as? String },
      ["restored", "already-present", "already-present", "unknown"],
      "同一リクエスト内の重複は 2 枚目が already-present・live の id も already-present・ログに無い id は unknown")
    XCTAssertEqual(wc.current.tabs.count, 2, "1 枚だけ足す")
    XCTAssertEqual(
      try results(wc.controlRestoreSessions(sessionIds: ["m-1"])).first?["status"] as? String,
      "already-present", "再実行は already-present（休眠チケットも present）")
  }
}
