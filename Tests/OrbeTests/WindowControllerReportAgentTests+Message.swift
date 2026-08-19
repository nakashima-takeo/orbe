import XCTest

@testable import Orbe

/// `report_agent` の文言の契約（ファイル分割の拡張）。message は state の遷移で確定し直し、
/// 同じ state が続くあいだはツール由来（`source == "tool"`）の文言を通知由来の報告で上書きしない。
/// 1 つの待ちを複数の hook が順に報告する CLI（claude）で具体的な文言が汎用の定型文に潰されないこと、
/// 通知由来どうしは上書きし合って別の待ちの文言が居残らないことを、実 payload に対応する出所つきの
/// 報告列で正面から固定する。出所の語（`"tool"` / `"notification"`）は orbe-report と
/// モジュールを共有しない文字列契約なので、ここでも語そのものを固定する。
extension WindowControllerReportAgentTests {

  /// 完了条件1: 1 つの待ちを 2 つの hook が順に報告しても、ツール由来の具体的な文言が残る
  /// （claude の AskUserQuestion: PreToolUse が質問文、約 6 秒後の Notification が定型文）。
  func testNotificationDoesNotOverwriteToolMessage() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "赤と青どちらが好きですか", source: "tool"))
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "Claude needs your permission", source: "notification"))
    XCTAssertEqual(pane.agentReport?.message?.text, "赤と青どちらが好きですか")
    // 文言を載せない報告もツール由来を落とせない（守る相手は通知由来に限らない）。
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: nil)
    XCTAssertEqual(pane.agentReport?.message?.text, "赤と青どちらが好きですか", "文言なしの報告でもツール由来は残る")
  }

  /// 完了条件4: ツール由来の文言を持たない待ちは、同 state の通知由来の報告が埋める
  /// （claude の ExitPlanMode: PreToolUse の tool_input に questions が無く文言なし、
  /// 約 6 秒後の Notification が plan approval の文言を載せる）。
  func testNotificationFillsWaitingThatStartedWithoutMessage() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: nil)
    XCTAssertNil(pane.agentReport?.message, "文言を載せない報告では文言なし")
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(
        text: "Claude Code needs your approval for the plan", source: "notification"))
    XCTAssertEqual(pane.agentReport?.message?.text, "Claude Code needs your approval for the plan")
    // 埋めた文言は通知由来なので、同 state の文言なしの報告で落ちる（stale にならない）。
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: nil)
    XCTAssertNil(pane.agentReport?.message, "通知由来は文言なしの報告で落ちる")
  }

  /// 完了条件2・3: state の遷移は文言を確定し直す。前の待ちの文言は working への遷移で消え、
  /// 次の待ち（本物の permission）の定型文と done の最終応答がそれぞれ載る。
  func testStateChangeRedeterminesMessage() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "赤と青どちらが好きですか", source: "tool"))
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    XCTAssertNil(pane.agentReport?.message, "working は文言を持たない")
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "Claude needs your permission", source: "notification"))
    XCTAssertEqual(pane.agentReport?.message?.text, "Claude needs your permission")
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "done", sessionId: nil,
      message: AgentMessage(text: "PR #142 を作成しました", source: "tool"))
    XCTAssertEqual(pane.agentReport?.message?.text, "PR #142 を作成しました")
  }

  /// 完了条件5: teammate の worker 承認要求が先に waiting を占めた状態でリーダー自身が質問する経路。
  /// worker の要求はリーダーの pane へ即時に届き、その承認では hook が発火しないので state は
  /// waiting のまま。そこへ来たツール由来の質問文は無条件に入る。
  func testToolMessageOverwritesNotificationMessage() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "agent-a needs permission for Bash", source: "notification"))
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "赤と青どちらが好きですか", source: "tool"))
    XCTAssertEqual(pane.agentReport?.message?.text, "赤と青どちらが好きですか")
  }

  /// 通知由来どうしは上書きし合う。連続する worker 承認要求では待ちの主体が入れ替わっており、
  /// 保持すると解決済みの要求の文言が誤情報として居残る。
  func testNotificationMessageOverwritesEarlierNotificationMessage() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "agent-a needs permission for Bash", source: "notification"))
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "agent-b needs permission for Write", source: "notification"))
    XCTAssertEqual(pane.agentReport?.message?.text, "agent-b needs permission for Write")
  }
}
