import AppKit
import XCTest

@testable import Orbe

/// タブのエージェント状態の読み（タブグリフ）と、`idle` への書き戻し（`TerminalTab+Agent`）。
///
/// `idle` への書き戻しの入口は 2 つ——タブ活性化による done のフォーカス消費（自動）と、
/// タブのコンテキストメニューによるリセット（ユーザー操作）。どちらも同一性・文言・
/// 状態変化時刻を運んだまま state だけ落とす。ここが崩れると resume できない agent が生まれるか、
/// Attention の並びが書き戻しのたびに先頭へ跳ねる。
///
/// `agent_state` 制御イベントとして何が流れるかは `AgentStateEmitTests` が、
/// メニューからの配線（宛先の解決・chrome 再投影）は `ChromeTabContextMenuTests` が持つ。
extension TerminalTabTests {

  // MARK: - agentStateKind

  func testGlyphNilWhenNoActiveState() {
    let none = TerminalTab(cwd: "/tmp")
    XCTAssertNil(none.agentStateKind, "nil ならアイコン無し")
    let idle = TerminalTab(cwd: "/tmp")
    setReportedState(idle, "idle")
    XCTAssertNil(idle.agentStateKind, "idle はタブに出ない")
  }

  func testGlyphMapsReportedState() {
    for (state, kind) in [
      ("waiting", AgentStateIcon.Kind.waiting), ("working", .working), ("done", .done),
    ] {
      let tab = TerminalTab(cwd: "/tmp")
      setReportedState(tab, state)
      XCTAssertEqual(tab.agentStateKind, kind)
    }
  }

  // MARK: - consumeDoneState

  func testConsumeSettlesDoneToIdle() {
    let tab = TerminalTab(cwd: "/tmp")
    setReportedState(tab, "done")

    tab.consumeDoneState()

    XCTAssertEqual(tab.agentState, "idle", "done は idle(休止)へ")
    XCTAssertNil(tab.agentStateKind, "idle はタブに出ない＝done バッジが消える")
  }

  func testConsumeKeepsWaitingAndWorking() {
    for state in ["waiting", "working"] {
      let tab = TerminalTab(cwd: "/tmp")
      setReportedState(tab, state)
      tab.consumeDoneState()
      XCTAssertEqual(tab.agentState, state, "\(state) は消費しない")
    }
  }

  func testConsumePreservesAgentSessionForResume() {
    let tab = TerminalTab(cwd: "/tmp")
    let session = AgentSession(command: "claude", sessionId: "sess-1")
    setReportedState(tab, "done", command: "claude", sessionId: "sess-1")

    tab.consumeDoneState()

    XCTAssertEqual(tab.agentState, "idle", "done は idle(休止)へ")
    XCTAssertEqual(tab.agentSlot.session, session, "resume 用の同一性（command・sessionId）は保持")
  }

  func testConsumeIsScopedToReceiverTab() {
    // ヘルパーはアクティブ表示タブにだけ consumeDoneState() を呼ぶ。
    // 消費は受け手タブに閉じ、別タブ（背景タブ）の done は残る。
    let active = TerminalTab(cwd: "/tmp")
    let background = TerminalTab(cwd: "/tmp")
    setReportedState(active, "done")
    setReportedState(background, "done")

    active.consumeDoneState()

    XCTAssertEqual(active.agentState, "idle", "受け手タブの done は idle(休止)へ")
    XCTAssertEqual(background.agentState, "done", "背景タブの done は残る")
  }

  func testConsumeOnNonDoneTabNoOp() {
    let tab = TerminalTab(cwd: "/tmp")

    tab.consumeDoneState()

    XCTAssertNil(tab.agentState)
    XCTAssertNil(tab.agentStateKind)
  }

  // MARK: - resetAgentState（タブのコンテキストメニューによるリセット）

  func testResetSettlesEveryReportedStateToIdle() {
    for state in ["waiting", "working", "done"] {
      let tab = TerminalTab(cwd: "/tmp")
      setReportedState(tab, state)
      XCTAssertNotNil(tab.agentStateKind, "前提: タブにグリフが出ている＝リセットできる")

      tab.resetAgentState()

      XCTAssertEqual(tab.agentState, "idle", "\(state) は idle へ")
      XCTAssertNil(tab.agentStateKind, "idle はタブに出ない＝グリフが消える")
    }
  }

  func testResetPreservesIdentityMessageAndStateChangedAt() {
    let tab = TerminalTab(cwd: "/tmp")
    let reportedAt = Date(timeIntervalSince1970: 1000)
    let question = AgentMessage(text: "approve?", source: "tool")
    let session = AgentSession(command: "claude", sessionId: "sess-1")
    setReportedState(tab, "waiting", at: reportedAt, message: question, sessionId: "sess-1")

    tab.resetAgentState()

    XCTAssertEqual(tab.agentState, "idle")
    XCTAssertEqual(tab.agentSlot.session, session, "resume 用の同一性（command・sessionId）は保持")
    XCTAssertEqual(tab.agentSlot.report?.message, question, "文言は保持")
    XCTAssertEqual(tab.agentSlot.report?.stateChangedAt, reportedAt, "報告以外の書き戻しは打刻を進めない")
  }

  func testResetIsScopedToReceiverTab() {
    let target = TerminalTab(cwd: "/tmp")
    let background = TerminalTab(cwd: "/tmp")
    setReportedState(target, "waiting")
    setReportedState(background, "waiting")

    target.resetAgentState()

    XCTAssertEqual(target.agentState, "idle", "受け手タブは idle へ")
    XCTAssertEqual(background.agentState, "waiting", "別タブの状態は残る")
  }

  func testResetLeavesSlotsWithoutAReportedStateUntouched() {
    let ticket = AgentSession(command: "claude", sessionId: "resume-1")
    let state = TabState(cwd: "/tmp", agent: ticket, explicitTitle: nil)
    let tabs = [
      TerminalTab(cwd: "/tmp"),
      TerminalTab(restoring: state, resumeSpawn: { _ in nil }),
      liveUnreportedTab(session: ticket),
    ]
    for tab in tabs {
      let slot = tab.agentSlot
      tab.resetAgentState()
      XCTAssertEqual(tab.agentSlot, slot, "素のシェル / 未消費チケット / 報告前の live には何も生やさない")
    }
  }

  /// グリフの出ていないタブはリセットするものを持たない（メニュー項目の無効条件と同じ集合）。
  func testGlyphlessTabHasNothingToReset() {
    let tab = TerminalTab(cwd: "/tmp")
    let reportedAt = Date(timeIntervalSince1970: 1000)
    setReportedState(tab, "idle", at: reportedAt)
    XCTAssertNil(tab.agentStateKind, "前提: idle だけのタブにグリフは出ない")

    tab.resetAgentState()

    XCTAssertEqual(tab.agentState, "idle")
    XCTAssertEqual(tab.agentSlot.report?.stateChangedAt, reportedAt, "打刻も動かない＝何も起きていない")
  }
}
