import Foundation

@testable import Orbe

/// いつの言葉が長い自動化（「平日 9:00〜18:50 の10分ごと」）と、言葉にせず式のまま出す自動化（「cron 15,45 8 * 1,7 *」）。
/// 一覧の 2 段目と詳細のいつが崩れないかを撮る。見本の今日（2025-10-04）は土曜なので、平日の回は前日に置く。
extension DesignSceneFixtures {
  static func boardCronExamples() -> [Automation] {
    [boardWorkingHours, boardHalfYear]
  }

  private static var boardWorkingHours: Automation {
    let runs = [(18, 50, 0), (18, 40, 2), (18, 30, 1)].map { hour, minute, fresh in
      automationRun(
        at: automationAt(hour, minute, daysAgo: 1), items: 40, fresh: fresh,
        proposed: min(fresh, 1))
    }
    return Automation(
      id: 5,
      definition: automationDefinition(
        "Sentry: 本番の新しいエラー",
        source: AutomationSource(
          method: .command(
            BackgroundCommand(script: "~/bin/sentry-issues.sh --env production", directory: nil)),
          coverage: .newArrivals),
        trigger: cron("*/10 9-18 * * 1-5"),
        instruction: "利用者に影響が出ているエラーだけをタスクにする。"),
      paused: false, createdAt: automationAt(9, 0, daysAgo: 7), lastFetched: [], reviewAll: false,
      lastRunAt: runs[0].startedAt, runs: runs)
  }

  private static var boardHalfYear: Automation {
    Automation(
      id: 6,
      definition: automationDefinition(
        "経費: 半期の立替の締め",
        source: AutomationSource(
          method: .command(BackgroundCommand(script: "~/bin/expenses.sh --open", directory: nil)),
          coverage: .currentSet),
        trigger: cron("15,45 8 * 1,7 *"),
        instruction: "締めまでに申請していない立替をタスクにする。"),
      paused: false, createdAt: automationAt(9, 0, daysAgo: 7), lastFetched: [], reviewAll: false,
      lastRunAt: nil, runs: [])
  }
}
