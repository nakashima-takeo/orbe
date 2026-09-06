import Foundation
import OrbeSessionLog
import XCTest

@testable import Orbe

/// 同一性（command + sessionId）の寿命の遷移が `TerminalTab` の 3 メソッドからどう出るかを固定する。
///
/// 壊れると何が起きるか: 記録漏れは `agent-sessions.jsonl` に「生きている」ままの同一性を残し、
/// 閉じたエージェント一覧に生きているセッションが出るか、閉じたものが永久に出ない。
/// 逆に余計な遷移は、同じ 1 つの opened に closed を 2 つ付ける。
final class TerminalTabIdentityTests: OrbeTestCase {
  private typealias Transition = TerminalTab.IdentityTransition

  private func recording(_ tab: TerminalTab) -> () -> [Transition] {
    var log: [Transition] = []
    tab.onIdentityTransition = { log.append($0) }
    return { log }
  }

  private let claude = SessionEvent.Agent(command: "claude", sessionId: "s-1")

  // MARK: applyReport

  func testFirstReportWithSessionIdOpens() {
    let tab = TerminalTab(cwd: "/tmp")
    let log = recording(tab)
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle"))
    XCTAssertEqual(log(), [], "sessionId を運ぶ前の稼働はまだ同一性ではない")
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))
    XCTAssertEqual(log(), [.opened(claude)], "sessionId が付いた瞬間に opened")
    tab.applyReport(AgentHookReport(agent: "claude", state: "working", sessionId: "s-1"))
    XCTAssertEqual(log(), [.opened(claude)], "同じ同一性の続報では何も出ない")
  }

  func testSessionSwitchClosesThenOpens() {
    let tab = TerminalTab(cwd: "/tmp")
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))
    let log = recording(tab)
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "s-2"))
    XCTAssertEqual(
      log(),
      [
        .closed(claude, origin: .agent, reason: nil),
        .opened(SessionEvent.Agent(command: "claude", sessionId: "s-2")),
      ], "A→B はこの順で closed(A, agent) → opened(B)")
  }

  func testClearClosesWithReason() {
    let tab = TerminalTab(cwd: "/tmp")
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))
    let log = recording(tab)
    tab.applyReport(
      AgentHookReport(
        agent: "claude", state: "clear", sessionId: nil, message: nil, reason: "logout"))
    XCTAssertEqual(log(), [.closed(claude, origin: .agent, reason: "logout")])
    XCTAssertEqual(tab.agentSlot, .none)
    tab.applyReport(
      AgentHookReport(
        agent: "claude", state: "clear", sessionId: nil, message: nil, reason: "other"))
    XCTAssertEqual(log().count, 1, "既に無い同一性の clear では何も出ない")
  }

  func testDormantDiscardsReportsWithoutTransition() {
    let tab = TerminalTab(
      restoring: TabState(
        cwd: "/tmp", agent: AgentSession(command: "claude", sessionId: "s-1"), explicitTitle: nil),
      resumeSpawn: { _ in nil })
    let log = recording(tab)
    XCTAssertFalse(
      tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "s-9")))
    XCTAssertEqual(log(), [], "未消費チケット宛の報告は破棄＝同一性も動かない")
    XCTAssertTrue(tab.isDormant)
  }

  func testReturnValueIsTheRealStateChange() {
    let tab = TerminalTab(cwd: "/tmp")
    XCTAssertTrue(
      tab.applyReport(AgentHookReport(agent: "claude", state: "working")))
    XCTAssertFalse(
      tab.applyReport(AgentHookReport(agent: "claude", state: "working")),
      "同値の連続報告は実変化でない")
    XCTAssertTrue(
      tab.applyReport(AgentHookReport(agent: "claude", state: "done")))
    XCTAssertTrue(
      tab.applyReport(AgentHookReport(agent: "claude", state: "clear")))
    XCTAssertFalse(
      tab.applyReport(AgentHookReport(agent: "claude", state: "clear")))
  }

  // MARK: recordMaterializationStarted

  func testWakingResolvedTicketOpens() {
    let tab = TerminalTab(
      restoring: TabState(
        cwd: "/tmp", agent: AgentSession(command: "claude", sessionId: "s-1"), explicitTitle: nil),
      resumeSpawn: { _ in ("claude --resume s-1", [:]) })
    let log = recording(tab)
    tab.recordMaterializationStarted()
    XCTAssertEqual(log(), [.opened(claude)])
    tab.recordMaterializationStarted()
    XCTAssertEqual(log().count, 1, "起床は一度きり")
  }

  func testWakingUnresolvedTicketClosesAsUnresolved() {
    let tab = TerminalTab(
      restoring: TabState(
        cwd: "/tmp", agent: AgentSession(command: "claude", sessionId: "s-1"), explicitTitle: nil),
      resumeSpawn: { _ in nil })
    let log = recording(tab)
    tab.recordMaterializationStarted()
    XCTAssertEqual(log(), [.closed(claude, origin: .unresolved, reason: nil)])
    XCTAssertEqual(tab.agentSlot, .none, "素シェル化")
  }

  // MARK: recordDetached

  func testDetachMirrorsTabCloseOrigin() {
    for (origin, expected) in [
      (TabCloseOrigin.gesture, SessionEvent.CloseOrigin.gesture), (.process, .process),
      (.controlAPI, .controlAPI),
    ] {
      let tab = TerminalTab(cwd: "/tmp")
      tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))
      let log = recording(tab)
      tab.recordDetached(origin: origin)
      XCTAssertEqual(log(), [.closed(claude, origin: expected, reason: nil)])
      XCTAssertEqual(tab.agentSlot.session?.sessionId, "s-1", "slot は触らない")
    }
  }

  func testDetachWithoutIdentityIsSilent() {
    let plain = TerminalTab(cwd: "/tmp")
    let plainLog = recording(plain)
    plain.recordDetached(origin: .gesture)
    let unnamed = TerminalTab(cwd: "/tmp")
    unnamed.applyReport(AgentHookReport(agent: "claude", state: "working"))
    let unnamedLog = recording(unnamed)
    unnamed.recordDetached(origin: .process)
    XCTAssertEqual(plainLog(), [], "素のシェルは記録しない")
    XCTAssertEqual(unnamedLog(), [], "sessionId 不明のまま閉じたタブは記録しない")
  }

  func testDetachAfterIdentityEndedIsSilent() {
    let tab = TerminalTab(cwd: "/tmp")
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))
    tab.applyReport(
      AgentHookReport(
        agent: "claude", state: "clear", sessionId: nil, message: nil, reason: "clear"))
    let log = recording(tab)
    tab.recordDetached(origin: .gesture)
    XCTAssertEqual(log(), [], "同一性が既に終わっているタブが閉じても何も書かない")
  }
}
