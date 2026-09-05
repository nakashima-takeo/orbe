import AppKit
import XCTest

@testable import Orbe

/// タブ内ペインのエージェント状態の読み（タブグリフ・横断ロールアップ向けの集約）と、
/// `idle` への書き戻し（`TerminalController+Agent`）。分割ツリーの不変条件は本体ファイルが持つ。
///
/// `idle` への書き戻しの入口は 2 つ——タブ活性化による done のフォーカス消費（自動）と、
/// タブのコンテキストメニューによる一括リセット（ユーザー操作）。どちらも同一性・文言・
/// 状態変化時刻を運んだまま state だけ落とす。ここが崩れると resume できない agent が生まれるか、
/// Attention の並びが書き戻しのたびに先頭へ跳ねる。
///
/// `agent_state` 制御イベントとして何が流れるかは `AgentStateEmitTests` が、
/// メニューからの配線（宛先の解決・chrome 再投影）は `ChromeTabContextMenuTests` が持つ。
extension TerminalControllerTests {

  // MARK: - aggregateAgentState

  func testAggregateNilWhenNoActiveState() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    pane(split.arrangedSubviews[0]).agentSlot = .none
    setReportedState(pane(split.arrangedSubviews[1]), "idle")
    XCTAssertNil(tc.aggregateAgentState(), "idle・nil のみならアイコン無し")
  }

  func testAggregatePicksWaitingOverWorking() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    let a = pane(split.arrangedSubviews[0])
    let b = pane(split.arrangedSubviews[1])
    setReportedState(a, "working")
    setReportedState(b, "waiting")
    XCTAssertEqual(tc.aggregateAgentState(), .waiting, "waiting > working")
  }

  // MARK: - consumeDoneState

  func testConsumeClearsAllDonePanesAcrossTab() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    let a = pane(split.arrangedSubviews[0])
    let b = pane(split.arrangedSubviews[1])
    setReportedState(a, "done")
    setReportedState(b, "done")

    tc.consumeDoneState()

    XCTAssertEqual(a.agentState, "idle", "done は idle(休止)へ")
    XCTAssertEqual(b.agentState, "idle", "done は idle(休止)へ")
    XCTAssertNil(tc.aggregateAgentState(), "idle はタブに出ない＝集約 done バッジが消える")
  }

  func testConsumeKeepsWaitingAndWorking() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    let a = pane(split.arrangedSubviews[0])
    let b = pane(split.arrangedSubviews[1])
    setReportedState(a, "waiting")
    setReportedState(b, "working")

    tc.consumeDoneState()

    XCTAssertEqual(a.agentState, "waiting", "waiting は消費しない")
    XCTAssertEqual(b.agentState, "working", "working は消費しない")
  }

  func testConsumePreservesAgentSessionForResume() {
    let tc = TerminalController()
    let a = tc.focusedPane!
    setReportedState(a, "done", command: "claude")
    let session = AgentSession(command: "claude", sessionId: "sess-1")
    if case .live(_, let report) = a.agentSlot {
      a.agentSlot = .live(session: session, report: report)
    }

    tc.consumeDoneState()

    XCTAssertEqual(a.agentState, "idle", "done は idle(休止)へ")
    XCTAssertEqual(a.agentSlot.session, session, "resume 用の同一性（command・sessionId）は保持")
  }

  func testConsumeIsScopedToReceiverTab() {
    // ヘルパーはアクティブ表示タブにだけ consumeDoneState() を呼ぶ。
    // 消費は受け手タブに閉じ、別タブ（背景タブ）の done は残る。
    let active = TerminalController()
    let background = TerminalController()
    setReportedState(active.focusedPane!, "done")
    setReportedState(background.focusedPane!, "done")

    active.consumeDoneState()

    XCTAssertEqual(active.focusedPane!.agentState, "idle", "受け手タブの done は idle(休止)へ")
    XCTAssertEqual(background.focusedPane!.agentState, "done", "背景タブの done は残る")
  }

  func testConsumeOnNonDonePaneNoOp() {
    let tc = TerminalController()
    let a = tc.focusedPane!
    a.agentSlot = .none

    tc.consumeDoneState()

    XCTAssertNil(a.agentState)
    XCTAssertNil(tc.aggregateAgentState())
  }

  // MARK: - resetAgentStates（タブのコンテキストメニューによる一括リセット）

  func testResetSettlesEveryReportedStateAcrossTabToIdle() {
    let tc = TerminalController()
    tc.split(.horizontal)
    tc.split(.vertical, from: tc.controlAllPanes().first!)
    let panes = tc.controlAllPanes()
    XCTAssertEqual(panes.count, 3, "前提: 3 ペイン")
    setReportedState(panes[0], "waiting")
    setReportedState(panes[1], "working")
    setReportedState(panes[2], "done")
    XCTAssertNotNil(tc.aggregateAgentState(), "前提: タブにグリフが出ている＝リセットできる")

    tc.resetAgentStates()

    XCTAssertEqual(
      panes.map(\.agentState), ["idle", "idle", "idle"], "waiting/working/done すべて idle へ")
    XCTAssertNil(tc.aggregateAgentState(), "idle はタブに出ない＝グリフが消える")
  }

  func testResetPreservesIdentityMessageAndStateChangedAt() {
    let tc = TerminalController()
    let a = tc.focusedPane!
    let reportedAt = Date(timeIntervalSince1970: 1000)
    let question = AgentMessage(text: "approve?", source: "tool")
    setReportedState(a, "waiting", at: reportedAt, message: question)
    let session = AgentSession(command: "claude", sessionId: "sess-1")
    if case .live(_, let report) = a.agentSlot {
      a.agentSlot = .live(session: session, report: report)
    }

    tc.resetAgentStates()

    XCTAssertEqual(a.agentState, "idle")
    XCTAssertEqual(a.agentSlot.session, session, "resume 用の同一性（command・sessionId）は保持")
    XCTAssertEqual(a.agentSlot.report?.message, question, "文言は保持")
    XCTAssertEqual(a.agentSlot.report?.stateChangedAt, reportedAt, "報告以外の書き戻しは打刻を進めない")
  }

  func testResetIsScopedToReceiverTab() {
    let target = TerminalController()
    let background = TerminalController()
    setReportedState(target.focusedPane!, "waiting")
    setReportedState(background.focusedPane!, "waiting")

    target.resetAgentStates()

    XCTAssertEqual(target.focusedPane!.agentState, "idle", "受け手タブのペインは idle へ")
    XCTAssertEqual(background.focusedPane!.agentState, "waiting", "別タブの状態は残る")
  }

  func testResetLeavesPanesWithoutAReportedStateUntouched() {
    let tc = TerminalController()
    tc.split(.horizontal)
    tc.split(.vertical, from: tc.controlAllPanes().first!)
    let panes = tc.controlAllPanes()
    XCTAssertEqual(panes.count, 3, "前提: 素のシェル / 未消費チケット / 報告前の live")
    let ticket = AgentSession(command: "claude", sessionId: "resume-1")
    panes[0].agentSlot = .none
    panes[1].agentSlot = .dormant(ticket)
    panes[2].agentSlot = .live(session: ticket, report: nil)

    tc.resetAgentStates()

    XCTAssertEqual(panes[0].agentSlot, .none, "素のシェルに agent を生やさない")
    XCTAssertEqual(panes[1].agentSlot, .dormant(ticket), "未消費チケットは消費しない")
    XCTAssertEqual(panes[2].agentSlot, .live(session: ticket, report: nil), "報告前の live に報告を作らない")
  }

  /// グリフの出ていないタブはリセットするものを持たない（メニュー項目の無効条件と同じ集合）。
  func testGlyphlessTabHasNothingToReset() {
    let tc = TerminalController()
    let a = tc.focusedPane!
    let reportedAt = Date(timeIntervalSince1970: 1000)
    setReportedState(a, "idle", at: reportedAt)
    XCTAssertNil(tc.aggregateAgentState(), "前提: idle だけのタブにグリフは出ない")

    tc.resetAgentStates()

    XCTAssertEqual(a.agentState, "idle")
    XCTAssertEqual(a.agentSlot.report?.stateChangedAt, reportedAt, "打刻も動かない＝何も起きていない")
  }

  // MARK: - agentStateCounts（横断集計の per-tab 基盤）

  func testAgentStateCountsTalliesPerState() {
    let tc = TerminalController()
    let a = tc.focusedPane!
    tc.split(.horizontal)  // root: [a, b]
    let b = pane(rootSplit(tc)!.arrangedSubviews[1])
    tc.focusedPaneChanged(b)
    tc.split(.vertical)  // b を縦分割 → [a, [b, c]]
    let bSplit = rootSplit(tc)!.arrangedSubviews[1] as! NSSplitView
    let c = pane(bSplit.arrangedSubviews[1])

    setReportedState(a, "working")
    setReportedState(b, "waiting")
    setReportedState(c, "working")

    let counts = tc.agentStateCounts()
    XCTAssertEqual(counts["working"], 2, "working は 2 ペイン")
    XCTAssertEqual(counts["waiting"], 1, "waiting は 1 ペイン")
    XCTAssertNil(counts["done"])
  }

  func testAgentStateCountsTalliesIdleButNotNil() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    setReportedState(pane(split.arrangedSubviews[0]), "idle")
    pane(split.arrangedSubviews[1]).agentSlot = .none
    XCTAssertEqual(tc.agentStateCounts()["idle"], 1, "idle は横断集計に数える")
    XCTAssertEqual(tc.agentStateCounts().count, 1, "nil は数えない")
  }
}
