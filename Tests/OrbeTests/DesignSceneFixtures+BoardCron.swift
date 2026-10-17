import Foundation

@testable import Orbe

/// いつの言葉が長い自動化（「平日 9:00〜18:50 の10分ごと」）と、言葉にせず式のまま出す自動化（「cron 15,45 8 * 1,7 *」）。
/// 一覧の 2 段目と詳細のいつが崩れないかを撮る。見本の今日（2025-10-04）は土曜なので、平日の回は前日に置く。
extension DesignSceneFixtures {
  static func boardCronExamples() -> [AutomationSample] {
    [boardWorkingHours, boardHalfYear]
  }

  private static var boardWorkingHours: AutomationSample {
    AutomationSample(
      definition: candidatesDefinition(
        "Sentry: 本番の新しいエラー",
        fetch: commandPart(
          "fetch", "Sentry から取る", .scheduled(cron("*/10 9-18 * * 1-5")),
          script: "~/bin/sentry-issues.sh --env production", coverage: .newArrivals),
        instruction: "利用者に影響が出ているエラーだけをタスクにする。"),
      createdAt: automationAt(9, 0, daysAgo: 7),
      passes: [(18, 30, 1), (18, 40, 2), (18, 50, 0)].flatMap { hour, minute, fresh in
        round(
          "sentry", at: automationAt(hour, minute, daysAgo: 1), items: 40, fresh: fresh,
          proposed: min(fresh, 1))
      })
  }

  private static var boardHalfYear: AutomationSample {
    AutomationSample(
      definition: candidatesDefinition(
        "経費: 半期の立替の締め",
        fetch: commandPart(
          "fetch", "立替を取る", .scheduled(cron("15,45 8 * 1,7 *")),
          script: "~/bin/expenses.sh --open", coverage: .currentSet),
        instruction: "締めまでに申請していない立替をタスクにする。"),
      createdAt: automationAt(9, 0, daysAgo: 7))
  }
}
