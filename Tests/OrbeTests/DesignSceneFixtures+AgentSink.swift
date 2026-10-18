import Foundation

@testable import Orbe

/// 見本『レビュー待ちの PR を Slack へ』: 入力の無い仕事の部品が、平日 9:00 に gh で調べて Slack に投稿する。通知は
/// メニューバー。応答の全文（複数行）・することが無いという申告（何もしなかった）・agent が失敗を申告した回・空の応答（完了）を
/// 持つ。見本の今日（2025-10-04）は土曜なので、回は前の平日に置く。
extension DesignSceneFixtures {
  static func boardAgentExample() -> AutomationSample {
    let outcomes: [(daysAgo: Int, outcome: AutomationPartPass.Outcome)] = [
      (4, worked(.done(nil))),
      (
        3,
        failed(
          "the part \"post\" reported an error: mcp__slack__slack_send_message was refused")
      ),
      (2, worked(.nothing("レビュー待ちの PR は無かった"))),
      (
        1,
        worked(
          .done(
            """
            レビュー待ちの PR 2 件を #dev-me に投稿した。
            - #412 エディターの折り返しを VS Code に寄せる（待ち 2 日）
            - #415 自動化の出力先に agent を足す（待ち 1 日）
            """))
      ),
    ]
    return AutomationSample(
      definition: AutomationDefinition(
        name: "レビュー待ちの PR を Slack へ", notify: .menuBar,
        parts: [
          agentPart(
            "post", "PR を投稿", .scheduled(cron("0 9 * * 1-5")),
            tools: ["Bash(gh search prs:*)", "mcp__slack__slack_send_message"],
            instruction: "自分がレビュー待ちの open な PR を gh で調べてまとめ、Slack の #dev-me に投稿して。",
            deliver: .report)
        ]),
      createdAt: automationAt(9, 0, daysAgo: 7),
      passes: outcomes.map {
        AutomationSamplePass(
          part: "post", at: automationAt(9, 0, daysAgo: $0.daysAgo), outcome: $0.outcome)
      })
  }
}
