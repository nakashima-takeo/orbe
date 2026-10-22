import Foundation

@testable import Orbe

/// 提案タブの見本（見本 R3Inbox.png と同じ並び）。
extension DesignSceneFixtures {
  static func automationItem(_ id: String, _ body: String, at time: Date) -> AutomationItem {
    AutomationItem(id: id, link: "https://example.slack.com/archives/\(id)", body: body, time: time)
  }

  /// 見本の 3 項目（見積もり・オンボーディング・週報）。
  static var automationEstimate: AutomationItem {
    automationItem(
      "D01-1", "@yamada · DM「見積もり、金曜までに送ってもらえますか？数字は先週の版で大丈夫です。」",
      at: automationAt(10, 24))
  }

  static var automationOnboarding: AutomationItem {
    automationItem(
      "C02-7", "@tanaka · #general「@nakatake 来週のオンボーディング、環境構築の手順を一度見てもらえますか」",
      at: automationAt(12, 41))
  }

  static var automationWeekly: AutomationItem {
    automationItem("C03-2", "#team-orbe「今週の進捗、金曜までに週報へお願いします」", at: automationAt(11, 5))
  }

  private static var backlogFetch: AutomationDefinition.Part {
    agentPart(
      "fetch", "Backlog から取る", .scheduled(.every(1800)), model: "haiku",
      tools: ["mcp__backlog__get_issues"], instruction: "自分が担当の未完了の課題を、更新の新しい順に 30 件取る。",
      coverage: .currentSet)
  }

  private static var slackFetch: AutomationDefinition.Part {
    commandPart(
      "fetch", "Slack から取る", .scheduled(cron("0 9,13,17 * * *")),
      script: "~/bin/slack-mentions --since 1d", coverage: .newArrivals)
  }

  /// 受信 4 つ（Slack の 2 つは cron の時刻で提案あり・Backlog は 30 分ごとの軽い agent で提案なし・GitHub は止めていて
  /// 前回が失敗）と、判断待ちの提案 3 件（期限あり / なし、付け先が orbe / Home / work）。Slack の 2 つは 1 件のリンクを
  /// 重ねて取っている。`workspaces` は提案 3 件の付け先、`estimateTitle` は 1 件目のタイトル（どちらも省けば見本どおり）。
  static func automationDesignSamples(
    workspaces: [UUID?]? = nil, estimateTitle: String = "見積もりを山田さんに送る"
  ) -> [AutomationSample] {
    let workspaces = workspaces ?? [taskWorkspaces.all[0].id, nil, taskWorkspaces.all[1].id]
    let (estimate, onboarding, weekly) = (
      automationEstimate, automationOnboarding, automationWeekly
    )
    let created = automationAt(9, daysAgo: 3)
    let fetchedAt = automationAt(13)
    let judgedAt = automationAt(13, 1)
    return [
      AutomationSample(
        definition: candidatesDefinition("Slack: 自分宛の DM・メンション", fetch: slackFetch),
        createdAt: created,
        passes: [
          AutomationSamplePass(
            part: "fetch", at: fetchedAt, outcome: fetched([estimate, onboarding])),
          AutomationSamplePass(
            part: "judge", at: judgedAt, trigger: .arrival,
            outcome: judged(
              [
                proposal(
                  estimate, estimateTitle, due: TaskItem.DueDate("2025-10-10"),
                  workspace: workspaces[0]),
                proposal(onboarding, "オンボーディングの環境構築手順を見る", workspace: workspaces[1]),
              ], rows: 2)),
        ]),
      AutomationSample(
        definition: candidatesDefinition(
          "Slack: 自分の発言",
          fetch: commandPart(
            "fetch", "Slack から取る", .scheduled(cron("0 18 * * *")),
            script: "~/bin/slack-mine --since 1d", coverage: .newArrivals)),
        createdAt: created,
        passes: [
          AutomationSamplePass(
            part: "fetch", at: fetchedAt, outcome: fetched([weekly, onboarding])),
          AutomationSamplePass(
            part: "judge", at: judgedAt, trigger: .arrival,
            outcome: judged(
              [
                proposal(
                  weekly, "週報に今週の進捗を書く", due: TaskItem.DueDate("2025-10-10"),
                  workspace: workspaces[2])
              ], rows: 2)),
        ]),
      inboxBacklog, inboxGitHub,
    ]
  }

  private static var backlogItem: AutomationItem {
    AutomationItem(
      id: "ORBE-12", link: "https://example.backlog.com/view/ORBE-12", body: "課題",
      time: automationAt(8))
  }

  /// 30 分ごとの軽い agent で提案なし。
  private static var inboxBacklog: AutomationSample {
    AutomationSample(
      definition: candidatesDefinition("Backlog: 自分が担当の未完了課題", fetch: backlogFetch),
      createdAt: automationAt(9, daysAgo: 3),
      passes: [
        AutomationSamplePass(
          part: "fetch", at: automationAt(15),
          outcome: fetched([backlogItem]), kept: [backlogItem])
      ])
  }

  /// 止めていて前回が失敗。
  private static var inboxGitHub: AutomationSample {
    AutomationSample(
      definition: candidatesDefinition(
        "GitHub: 自分へのレビュー依頼",
        fetch: commandPart(
          "fetch", "GitHub から取る", .scheduled(.every(3600)),
          script: "gh search prs --review-requested=@me --json url", coverage: .currentSet)),
      createdAt: automationAt(9, daysAgo: 3), paused: true,
      passes: [
        AutomationSamplePass(
          part: "fetch", at: automationAt(9),
          outcome: failed("gh: Not Found (HTTP 404)"))
      ])
  }

  /// 長いタイトル・長い本文・多い提案（棚の 1 つ目に 14 件）。
  static func automationCrowdedSamples() -> [AutomationSample] {
    var samples = automationDesignSamples()
    let long =
      "@sato · #incident「本番のログイン直後に白画面になる件、再現手順と影響範囲をまとめて、明日の朝会までに"
      + "共有してもらえますか。顧客からの問い合わせが 3 件来ています。ログは添付のとおりで、Safari だけで起きているようです。」"
    let items = (0..<12).map { n in
      automationItem(
        "L\(n)", n == 0 ? long : "@user\(n) · DM「確認をお願いします \(n)」", at: automationAt(9, n))
    }
    samples[0].passes.insert(
      contentsOf: [
        AutomationSamplePass(part: "fetch", at: automationAt(9), outcome: fetched(items)),
        AutomationSamplePass(
          part: "judge", at: automationAt(9, 1), trigger: .arrival,
          outcome: judged(
            items.enumerated().map { n, item in
              proposal(
                item,
                n == 0
                  ? "本番のログイン直後に白画面になる件の再現手順と影響範囲をまとめて朝会で共有する" : "確認の依頼 \(n) に返事をする",
                due: n.isMultiple(of: 3) ? TaskItem.DueDate("2025-10-06") : nil)
            }, rows: items.count)),
      ], at: 0)
    return samples
  }
}
