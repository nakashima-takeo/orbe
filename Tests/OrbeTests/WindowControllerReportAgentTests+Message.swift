import XCTest

@testable import Orbe

/// `report_agent` の文言の契約（ファイル分割の拡張）。message は state の遷移で確定し、
/// 未確定〔nil〕なら同 state の後続報告が埋める＝1 つの state が続く区間では最初に得た文言を保つ。
/// 1 つの待ちを複数の hook が順に報告する CLI（claude）で、具体的な文言が汎用の定型文に潰されないこと、
/// 文言なしで始まった待ちが後から埋まること、遷移では確定し直すことを、報告列で正面から固定する。
extension WindowControllerReportAgentTests {

  /// 完了条件1: 1 つの待ちを 2 つの hook が順に報告しても、先に来た具体的な文言が残る
  /// （claude の AskUserQuestion: PreToolUse が質問文、約 6 秒後の Notification が定型文）。
  func testWaitingKeepsFirstMessageOfEpisode() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: "赤と青どちらが好きですか")
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: "Claude needs your permission")
    XCTAssertEqual(pane.agentMessage, "赤と青どちらが好きですか")
  }

  /// 完了条件4: 文言なしで始まった待ちは、同 state の後続報告が埋める
  /// （claude の ExitPlanMode: PreToolUse の tool_input に questions が無く文言なし、
  /// 約 6 秒後の Notification が plan approval の文言を載せる）。
  func testWaitingFillsMessageWhenEpisodeStartedEmpty() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: nil)
    XCTAssertNil(pane.agentMessage, "確定前は文言なし")
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: "Claude Code needs your approval for the plan")
    XCTAssertEqual(pane.agentMessage, "Claude Code needs your approval for the plan")
  }

  /// 完了条件2・3: state の遷移は文言を確定し直す。前の待ちの文言は working への遷移で消え、
  /// 次の待ち（本物の permission）の定型文と done の最終応答がそれぞれ載る。
  func testStateChangeRedeterminesMessage() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: "赤と青どちらが好きですか")
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    XCTAssertNil(pane.agentMessage, "working は文言を持たない")
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: "Claude needs your permission")
    XCTAssertEqual(pane.agentMessage, "Claude needs your permission")
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "done", sessionId: nil, message: "PR #142 を作成しました")
    XCTAssertEqual(pane.agentMessage, "PR #142 を作成しました")
  }
}
