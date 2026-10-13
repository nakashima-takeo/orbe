import Foundation

@testable import Orbe

/// 見本『レビュー待ちの PR を Slack へ』: 取得元も段も無く、毎朝 9:00 に出力先の agent が gh で調べて Slack に投稿する。通知は
/// メニューバー。応答の全文（複数行）・応答なし（完了）・agent が失敗を申告した回を持つ。
extension DesignSceneFixtures {
  private static func agentRun(daysAgo: Int, text: String?, failure: String? = nil) -> AutomationRun
  {
    let start = automationAt(9, 0, daysAgo: daysAgo)
    return AutomationRun(
      startedAt: start, endedAt: start.addingTimeInterval(70), trigger: .schedule, source: nil,
      fresh: nil, steps: [], lastStepCountedBySink: false,
      sink: .agent(
        AutomationAgentReport(
          commandLine: "claude -p --model sonnet", ending: "exited 0", text: text)),
      failure: failure)
  }

  static func boardAgentExample() -> Automation {
    let runs = [
      agentRun(
        daysAgo: 0,
        text: """
          レビュー待ちの PR 2 件を #dev-me に投稿した。
          - #412 エディターの折り返しを VS Code に寄せる（待ち 2 日）
          - #415 自動化の出力先に agent を足す（待ち 1 日）
          """),
      agentRun(daysAgo: 1, text: nil),
      agentRun(
        daysAgo: 2, text: nil,
        failure: "the sink agent reported an error: mcp__slack__slack_send_message was refused"),
      agentRun(daysAgo: 3, text: "レビュー待ちの PR は無かったので、投稿していない。"),
    ]
    return Automation(
      id: 6,
      definition: AutomationDefinition(
        name: "レビュー待ちの PR を Slack へ", trigger: .daily([.init(hour: 9, minute: 0)]),
        source: nil, steps: [],
        sink: .agent(
          AutomationSinkAgent(
            cli: "claude", model: nil,
            tools: ["Bash(gh search prs:*)", "mcp__slack__slack_send_message"],
            request:
              "自分がレビュー待ちの open な PR を gh で調べてまとめ、Slack の #dev-me に投稿して。土日なら何もしない。")),
        notify: .menuBar),
      paused: false, createdAt: automationAt(9, 0, daysAgo: 7), lastFetched: [], reviewAll: false,
      lastRunAt: runs[0].startedAt, runs: runs)
  }
}
