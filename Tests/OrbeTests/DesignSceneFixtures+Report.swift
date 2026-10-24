import Foundation

@testable import Orbe

/// 見本 B2『開いている PR の要約』: 毎日 18:00 に開いている PR を取り、届いたら要約のノードが報告として残す。通知は
/// メニューバー。報告の全文（複数行）・報告なし・失敗の回を持つ。
extension DesignSceneFixtures {
  static func boardReportExample() -> AutomationSample {
    let reports: [(daysAgo: Int, report: AutomationNodePass.Outcome)] = [
      (5, reported("開いている PR は 4 件。新しく 2 件が開いた。")),
      (4, failed("Claude usage limit reached")),
      (3, reported(nil)),
      (2, reported("開いている PR は 2 件。どちらもレビュー済みでマージ待ち。")),
      (
        1,
        reported(
          """
          開いている PR は 3 件。うち 1 件はレビュー待ちが 2 日を超えている。
          - #412 エディターの折り返しを VS Code に寄せる（レビュー待ち 2 日）
          - #415 自動化の報告を出力先に足す（CI 失敗: lint）
          - #416 依存の更新（自動マージ待ち）
          """)
      ),
    ]
    return AutomationSample(
      definition: AutomationDefinition(
        name: "開いている PR の要約", notify: .menuBar,
        nodes: [
          commandNode(
            "fetch", "開いている PR を取る", .scheduled(cron("0 18 * * *")),
            script:
              "gh pr list --json number,url,title,createdAt | jq -c '.[] | {id: (.number|tostring), "
              + "link: .url, body: .title, time: .createdAt}'",
            coverage: .currentSet),
          AutomationGraphTests.taking(
            .all,
            agentNode(
              "digest", "要約", .arrival, from: ["fetch"], model: "sonnet",
              instruction: "開いている PR を 3 行以内で要約する。", deliver: .report)),
        ]),
      createdAt: automationAt(9, 0, daysAgo: 7),
      passes: reports.flatMap { entry in
        let start = automationAt(18, 0, daysAgo: entry.daysAgo)
        return [
          AutomationSamplePass(
            nodeKey: "fetch", at: start,
            outcome: fetched(sampleItems("prs", 2 + entry.daysAgo % 3, at: start))),
          AutomationSamplePass(
            nodeKey: "digest", at: start.addingTimeInterval(60), trigger: .arrival,
            outcome: entry.report),
        ]
      })
  }

  /// 『開いている PR の要約』の通知先を通知センターにしたもの。
  static func boardReportNotificationCenterExample() -> AutomationSample {
    var sample = boardReportExample()
    sample.definition.notify = .notificationCenter
    return sample
  }

  /// 段の多い例に通知を付けたもの。流れの下に累計と通知の注記が 2 行で並ぶ。
  static func boardStepsNotifyExample() -> AutomationSample {
    var sample = boardStepsExample()
    sample.definition.notify = .menuBar
    return sample
  }
}
