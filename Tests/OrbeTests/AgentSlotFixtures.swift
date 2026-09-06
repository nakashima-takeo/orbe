import Foundation

@testable import Orbe

/// タブへ「稼働中の自己報告」を 1 発で立てるテスト用ヘルパ。production の報告経路（`applyReport`）を
/// そのまま通す——slot の外部代入は無いので、テストも同じ 1 経路で立てる。同一性はテストが読まない
/// 限りダミーで良い。
func setReportedState(
  _ tab: TerminalTab, _ state: String, at date: Date = Date(),
  message: AgentMessage? = nil, command: String = "claude", sessionId: String? = nil
) {
  tab.applyReport(
    AgentHookReport(agent: command, state: state, sessionId: sessionId, message: message),
    now: date)
}

/// タブのエージェントを終わらせる（hook の `clear` 報告と同じ経路。`.none` なら no-op）。
func clearAgentState(_ tab: TerminalTab) {
  tab.applyReport(AgentHookReport(agent: "claude", state: "clear"))
}

/// 報告前の稼働（`.live(session, report: nil)`）を持つタブ。production でこの形が生まれる唯一の経路
/// ＝休眠チケットの起床（resume が解けた直後・最初の hook 報告前）を踏む。
func liveUnreportedTab(session: AgentSession, cwd: String = "/tmp") -> TerminalTab {
  let tab = TerminalTab(
    restoring: TabState(cwd: cwd, agent: session, explicitTitle: nil),
    resumeSpawn: { session in ("\(session.command) --resume \(session.sessionId ?? "")", [:]) })
  tab.recordMaterializationStarted()
  return tab
}
