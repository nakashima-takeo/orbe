import Foundation

@testable import Orbe

/// 見本 B2『開いている PR の要約』: 毎日 18:00 に開いている PR を取り、段 1 つが要約を書いて報告として残す。通知は
/// メニューバー。報告の全文（複数行）・報告なし・失敗の回を持つ。
extension DesignSceneFixtures {
  private static func reportRun(
    daysAgo: Int, source: Int, report: String?, failure: String? = nil
  ) -> AutomationRun {
    let start = automationAt(18, 0, daysAgo: daysAgo)
    return AutomationRun(
      startedAt: start, endedAt: start.addingTimeInterval(40), trigger: .schedule,
      source: AutomationStepReport(
        name: nil, commandLine: "gh pr list", ending: "exited 0", count: source,
        rejected: AutomationRejections()),
      fresh: source,
      steps: [
        AutomationStepReport(
          name: "要約", commandLine: "claude -p", ending: failure == nil ? "exited 0" : "exited 1",
          count: report == nil ? 0 : 1, rejected: AutomationRejections())
      ],
      sink: failure == nil ? .report(text: report) : nil, failure: failure)
  }

  static func boardReportExample() -> Automation {
    let runs = [
      reportRun(
        daysAgo: 1, source: 3,
        report: """
          開いている PR は 3 件。うち 1 件はレビュー待ちが 2 日を超えている。
          - #412 エディターの折り返しを VS Code に寄せる（レビュー待ち 2 日）
          - #415 自動化の報告を出力先に足す（CI 失敗: lint）
          - #416 依存の更新（自動マージ待ち）
          """),
      reportRun(daysAgo: 2, source: 2, report: "開いている PR は 2 件。どちらもレビュー済みでマージ待ち。"),
      reportRun(daysAgo: 3, source: 2, report: nil),
      reportRun(
        daysAgo: 4, source: 4, report: nil,
        failure: "the step \"要約\" ended: exited 1: Claude usage limit reached"),
      reportRun(daysAgo: 5, source: 4, report: "開いている PR は 4 件。新しく 2 件が開いた。"),
    ]
    return Automation(
      id: 5,
      definition: AutomationDefinition(
        name: "開いている PR の要約", trigger: .daily([.init(hour: 18, minute: 0)]),
        source: AutomationSource(
          method: .command(
            BackgroundCommand(
              script:
                "gh pr list --json number,url,title,createdAt | jq -c '.[] | {id: (.number|tostring), "
                + "link: .url, body: .title, time: .createdAt}'",
              directory: nil)),
          coverage: .everything),
        steps: [
          AutomationStep(
            name: "要約",
            method: .agent(
              AutomationStepAgent(
                cli: "claude", model: "sonnet", instruction: "開いている PR を 3 行以内で要約する。")))
        ],
        sink: .report, notify: .menuBar),
      paused: false, createdAt: automationAt(9, 0, daysAgo: 7), lastFetched: [], reviewAll: false,
      lastRunAt: runs[0].startedAt, runs: runs)
  }

  /// 『開いている PR の要約』の通知先を通知センターにしたもの。
  static func boardReportNotificationCenterExample() -> Automation {
    var automation = boardReportExample()
    automation.redefine { $0.notify = .notificationCenter }
    return automation
  }

  /// 段の多い例に通知を付けたもの。出力先の段に累計と通知の注記が 2 行で並ぶ。
  static func boardStepsNotifyExample() -> Automation {
    var automation = boardStepsExample()
    automation.redefine { $0.notify = .menuBar }
    return automation
  }
}
