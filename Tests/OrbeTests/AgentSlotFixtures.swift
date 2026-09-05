import Foundation

@testable import Orbe

/// タブへ「稼働中の自己報告」を 1 発で立てるテスト用ヘルパ（production の report 経路を通さず
/// slot を直接組む）。同一性はテストが読まない限りダミーで良い。
func setReportedState(
  _ tab: TerminalTab, _ state: String, at date: Date = Date(),
  message: AgentMessage? = nil, command: String = "claude"
) {
  tab.agentSlot = .live(
    session: AgentSession(command: command, sessionId: nil),
    report: AgentReport(state: state, message: message, stateChangedAt: date))
}
