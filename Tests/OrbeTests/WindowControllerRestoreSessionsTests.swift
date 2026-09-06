import AppKit
import OrbeSessionLog
import XCTest

@testable import Orbe

/// `restore_sessions` の実体（`controlRestoreSessions`）を実 `WindowController` で固定する——ログの
/// 復元先を rootPath で照合し、無ければ作り、休眠チケットとして末尾に足し、選択もアクティブ化もしない。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerRestoreSessionsTests: OrbeTestCase {
  private func restore() throws -> WindowController {
    let plain = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: "/tmp/main", activeTab: 0, tabs: [plain]),
        WorkspaceState(name: "bg", rootPath: "/tmp/bg", activeTab: 0, tabs: [plain]),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  private func closed(
    _ id: String, rootPath: String, name: String = "gone", cwd: String = "/tmp/x"
  ) -> SessionEvent {
    SessionEvent(
      ts: Date(), kind: .closed(origin: .process, reason: nil),
      workspace: .init(name: name, rootPath: rootPath), cwd: cwd,
      agent: .init(command: "claude", sessionId: id))
  }

  private func results(_ result: Result<Any, ControlError>) throws -> [[String: Any]] {
    guard case .success(let value) = result else { throw XCTSkip("failure") }
    return try XCTUnwrap((value as? [String: Any])?["results"] as? [[String: Any]])
  }

  func testRestoresIntoTheMatchingWorkspaceWithoutSelectingOrActivating() throws {
    let wc = try restore()
    wc.sessionLog.record(closed("b-1", rootPath: "/tmp/bg", cwd: "/tmp/bg/src"))

    let rows = try results(wc.controlRestoreSessions(sessionIds: ["b-1"]))

    XCTAssertEqual(rows.map { $0["status"] as? String }, ["restored"])
    XCTAssertEqual(rows[0]["workspaceId"] as? Int, wc.workspaces[1].id)
    let tab = try XCTUnwrap(wc.workspaces[1].tabs.last)
    XCTAssertEqual(rows[0]["tabId"] as? Int, tab.id)
    XCTAssertTrue(tab.isDormant, "休眠チケットのまま（起こさない）")
    XCTAssertEqual(tab.cwd, "/tmp/bg/src")
    XCTAssertEqual(wc.workspaces[1].active, 0, "背景 WS の選択は動かさない")
    XCTAssertEqual(wc.activeWorkspace, 0, "前面化しない")
    XCTAssertEqual(wc.sessionLog.lastEvent(sessionId: "b-1")?.closeOrigin, .process, "復元では書かない")
  }

  func testCreatesTheWorkspaceFromTheLogWhenNoneMatches() throws {
    let wc = try restore()
    wc.sessionLog.record(closed("n-1", rootPath: "/tmp/new", name: "newws"))

    let rows = try results(wc.controlRestoreSessions(sessionIds: ["n-1"]))

    XCTAssertEqual(wc.workspaces.count, 3)
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
