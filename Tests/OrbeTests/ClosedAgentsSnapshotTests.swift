import Foundation
import OrbeSessionLog
import XCTest

@testable import Orbe

/// ⇧⌘T 一覧の導出（pure）。壊れると別 workspace で閉じたものが混ざるか、並びが古い順になる。
final class ClosedAgentsSnapshotTests: OrbeTestCase {
  private let base = Date(timeIntervalSince1970: 1_800_000_000)

  private func event(
    _ id: String, at seconds: TimeInterval, closed: SessionEvent.CloseOrigin? = nil,
    rootPath: String = "/repo", title: String? = nil
  ) -> SessionEvent {
    SessionEvent(
      ts: base.addingTimeInterval(seconds),
      kind: closed.map { .closed(origin: $0, reason: nil, title: title) } ?? .opened,
      workspace: .init(name: "ws", rootPath: rootPath), cwd: rootPath + "/src/\(id)",
      agent: .init(command: "claude", sessionId: id))
  }

  func testItemsAreFilteredByRootPathExcludePresentAndRunNewestFirst() {
    let events = [
      event("a", at: 0), event("b", at: 0), event("other", at: 0, rootPath: "/elsewhere"),
      event("a", at: 10, closed: .process, title: "deploy-api"),
      event("b", at: 12, closed: .process),
      event("other", at: 13, closed: .process, rootPath: "/elsewhere"),
      event("c", at: 0), event("c", at: 100, closed: .gesture, title: "release notes"),
      event("live", at: 0),
    ]
    let items = ClosedAgentsSnapshot.items(events: events, present: [], rootPath: "/repo")

    XCTAssertEqual(items.map(\.sessionId), ["c", "b", "a"], "平らに新しい順・他 WS は落ちる・生きているものは出ない")
    XCTAssertEqual(items.map(\.origin), [.gesture, .process, .process])
    XCTAssertEqual(
      items.map(\.title), ["release notes", nil, "deploy-api"], "closed の title をそのまま持つ")
    XCTAssertEqual(items[2].rootPath, "/repo")
    XCTAssertEqual(items[2].cwd, "/repo/src/a")
    XCTAssertEqual(
      ClosedAgentsSnapshot.items(events: events, present: ["b"], rootPath: "/repo").map(
        \.sessionId),
      ["c", "a"], "present は除く")
    XCTAssertTrue(
      ClosedAgentsSnapshot.items(events: events, present: [], rootPath: "/nowhere").isEmpty,
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
