import Foundation
import OrbeSessionLog
import XCTest

@testable import Orbe

/// ⇧⌘T 一覧の導出（pure）。壊れると別 workspace で閉じたものが混ざるか、並びが古い順になる。
final class ClosedAgentsSnapshotTests: OrbeTestCase {
  private let base = Date(timeIntervalSince1970: 1_800_000_000)

  private func event(
    _ id: String, at seconds: TimeInterval, closed: SessionEvent.CloseOrigin? = nil,
    rootPath: String = "/repo", reason: String? = nil
  ) -> SessionEvent {
    SessionEvent(
      ts: base.addingTimeInterval(seconds),
      kind: closed.map { .closed(origin: $0, reason: reason) } ?? .opened,
      workspace: .init(name: "ws", rootPath: rootPath), cwd: rootPath + "/src/\(id)",
      agent: .init(command: "claude", sessionId: id))
  }

  func testGroupsAreFilteredByRootPathAndNewestFirst() {
    let events = [
      event("a", at: 0), event("b", at: 0), event("other", at: 0, rootPath: "/elsewhere"),
      event("a", at: 10, closed: .process), event("b", at: 12, closed: .process),
      event("other", at: 13, closed: .process, rootPath: "/elsewhere"),
      event("c", at: 0), event("c", at: 100, closed: .gesture),
    ]
    let groups = ClosedAgentsSnapshot.groups(events: events, present: [], rootPath: "/repo")

    XCTAssertEqual(groups.map(\.origin), [.gesture, .process], "新しい順")
    XCTAssertEqual(groups[1].items.map(\.sessionId), ["b", "a"], "群内も新しい順・他 WS のメンバーは落ちる")
    XCTAssertEqual(groups[1].atKey, SessionEvent.iso8601(base.addingTimeInterval(10)))
    XCTAssertEqual(groups[1].items[0].rootPath, "/repo")
    XCTAssertEqual(groups[1].items[0].cwd, "/repo/src/b")
    XCTAssertTrue(
      ClosedAgentsSnapshot.groups(events: events, present: [], rootPath: "/nowhere").isEmpty,
      "一致する workspace が無ければ空")
  }

  func testPresentSessionIdsSpanLiveAndDormantTabsOfEveryWorkspace() {
    let live = Workspace(name: "live", rootPath: "/tmp")
    let liveTab = TerminalTab(cwd: "/tmp")
    liveTab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "l-1"))
    let unnamed = TerminalTab(cwd: "/tmp")
    unnamed.applyReport(AgentHookReport(agent: "claude", state: "idle"))
    live.tabs = [liveTab, unnamed, TerminalTab(cwd: "/tmp")]
    let dormant = Workspace(name: "dormant", rootPath: "/tmp")
    dormant.tabs = [
      TerminalTab(
        restoring: TabState(
          cwd: "/tmp", agent: AgentSession(command: "codex", sessionId: "d-1"), explicitTitle: nil),
        resumeSpawn: { _ in nil })
    ]

    XCTAssertEqual(ClosedAgentsSnapshot.presentSessionIds(of: [live, dormant]), ["l-1", "d-1"])
  }
}
