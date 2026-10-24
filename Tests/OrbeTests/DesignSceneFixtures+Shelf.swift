import Foundation

@testable import Orbe

/// 提案タブの棚の見本（見本 O2Palette の並び）。前回の判定の成否・まだ判定していない・停止中・判定ごとの最新の回・出どころの部品の
/// 名前を張る。
///
/// 1. 受け持ちの全部: 取得 3 つ（GitHub・Backlog・Slack）→ 判定「開発の依頼を選ぶ」（毎日 9:00。GitHub と Backlog から
///    12 件 → 候補 2。#405 には候補にした理由）と判定「返事が要る連絡を選ぶ」（毎日 13:00。制限時間で失敗）。棚には消えた自動化 6 の候補も出る（出どころの部品の名前を引けない）。
/// 2. Sentry: 新しいエラー（届いたらの判定。候補 1）。
/// 3. 長い名前の自動化（手動の判定。候補 1）。
/// 4. CI: main の失敗（届いたらの判定。候補なし）。
/// 5. GitHub: 自分へのレビュー依頼（止めていて、取得が失敗。候補なし）。
/// 6. 消えた自動化（GitHub の 1 項目を自動化 1 と重ねて取り、候補にした）。
extension DesignSceneFixtures {
  static func automationShelfSamples() -> [AutomationSample] {
    let github = shelfGitHubItems
    return [
      shelfOwned(github), shelfSentry, shelfManual, shelfCI, shelfPaused,
      shelfDeleted(github[6]),
    ]
  }

  private static func shelfItem(
    _ id: String, _ link: String, _ body: String, at time: Date
  ) -> AutomationItem {
    AutomationItem(id: id, link: link, body: body, time: time)
  }

  private static func shelfProposal(
    _ nodeKey: String, _ item: AutomationItem, _ title: String, due: TaskItem.DueDate? = nil,
    reason: String? = nil
  ) -> AutomationNodePass.Proposal {
    proposal(item, title, due: due, reason: reason)
  }

  /// GitHub の 7 項目。先頭がレビュー依頼の #405、末尾が自動化 6 と重ねて取る #398。
  private static var shelfGitHubItems: [AutomationItem] {
    let review = shelfItem(
      "405", "https://github.com/acme/storefront/pull/405",
      "suzuki がレビューを依頼\n#405 chore(deps): bump next from 14.2.3 to 14.2.15\n\n"
        + "next のパッチ更新。画像の最適化まわりの脆弱性修正を含むため、今週中に入れたいです。e2e は通っています。",
      at: automationAt(18, 20, daysAgo: 1))
    let others = (1...5).map { n in
      shelfItem(
        "40\(n - 1)", "https://github.com/acme/storefront/pull/40\(n - 1)", "PR #40\(n - 1)",
        at: automationAt(8, n, daysAgo: 1))
    }
    let failing = shelfItem(
      "398", "https://github.com/acme/storefront/actions/runs/398",
      "checkout.spec.ts が 3 回続けて失敗", at: automationAt(8, 40))
    return [review] + others + [failing]
  }

  private static func shelfOwned(_ github: [AutomationItem]) -> AutomationSample {
    let backlog =
      [
        shelfItem(
          "BLG-231", "https://example.backlog.com/view/BLG-231", "「購入する」を「注文を確定する」に統一",
          at: automationAt(8, 40))
      ]
      + (1...4).map { n in
        shelfItem(
          "BLG-22\(n)", "https://example.backlog.com/view/BLG-22\(n)", "課題 \(n)",
          at: automationAt(8, n))
      }
    let slack = sampleItems("slack", 3, at: automationAt(12, 50))
    let definition = AutomationDefinition(
      name: "受け持ちの全部", notify: nil,
      nodes: [
        commandNode(
          "github", "GitHub", .scheduled(.every(3600)),
          script: "gh search prs --review-requested=@me --json url,title", coverage: .currentSet),
        commandNode(
          "backlog", "Backlog", .scheduled(.every(3600)),
          script: "~/bin/backlog-mine", coverage: .currentSet),
        commandNode(
          "slack", "Slack", .scheduled(.every(1800)),
          script: "~/bin/slack-mentions --since 1d", coverage: .newArrivals),
        agentNode(
          "dev", "開発の依頼を選ぶ", .scheduled(cron("0 9 * * *")), from: ["github", "backlog"],
          instruction: "自分がレビューか修正を頼まれているものだけをタスクにする。", deliver: .taskCandidates),
        agentNode(
          "contact", "返事が要る連絡を選ぶ", .scheduled(cron("0 13 * * *")), from: ["slack"],
          instruction: "自分が返事を頼まれているものだけをタスクにする。", deliver: .taskCandidates),
      ])
    return AutomationSample(
      definition: definition, createdAt: automationAt(9, daysAgo: 3),
      passes: [
        AutomationSamplePass(
          nodeKey: "github", at: automationAt(8, 58), outcome: fetched(github)),
        AutomationSamplePass(
          nodeKey: "backlog", at: automationAt(8, 59), outcome: fetched(backlog)),
        AutomationSamplePass(
          nodeKey: "dev", at: automationAt(9),
          outcome: judged(
            [
              shelfProposal(
                "github", github[0], "#405 storefront の依存更新 をレビュー",
                reason: "あなたにレビューが依頼されていて、まだ応えていない。脆弱性の修正を含むので早めの確認が要る。"),
              shelfProposal(
                "backlog", backlog[0], "BLG-231 決済画面の文言を直す", due: TaskItem.DueDate("2025-10-07")),
            ], rows: 12)),
        AutomationSamplePass(
          nodeKey: "slack", at: automationAt(12, 58), outcome: fetched(slack)),
        AutomationSamplePass(
          nodeKey: "contact", at: automationAt(13),
          outcome: failed("", ending: .timeLimit, count: 3)),
      ])
  }

  private static var shelfSentry: AutomationSample {
    let items = [
      shelfItem(
        "E-1", "https://sentry.example.com/issues/1",
        "storefront で 37 件\nTypeError: cart is undefined",
        at: automationAt(14, 30))
    ]
    return AutomationSample(
      definition: candidatesDefinition(
        "Sentry: 新しいエラー",
        fetch: commandNode(
          "fetch", "Sentry", .scheduled(.every(1800)), script: "~/bin/sentry-new",
          coverage: .newArrivals)),
      createdAt: automationAt(9, daysAgo: 3),
      passes: [
        AutomationSamplePass(
          nodeKey: "fetch", at: automationAt(14, 30), outcome: fetched(items)),
        AutomationSamplePass(
          nodeKey: "judge", at: automationAt(14, 31), trigger: .arrival,
          outcome: judged([proposal(items[0], "TypeError: cart is undefined を直す")], rows: 1)),
      ])
  }

  private static var shelfManual: AutomationSample {
    let items = [
      shelfItem(
        "M-1", "https://example.slack.com/archives/M-1", "来週までに概算をお願いできますか",
        at: automationAt(10, 12))
    ]
    var definition = candidatesDefinition(
      "Slack: 自分宛の DM・メンションのうち、返事か作業を頼まれているもの",
      fetch: commandNode(
        "fetch", "Slack", .scheduled(.every(1800)), script: "~/bin/slack-mentions",
        coverage: .newArrivals))
    definition.nodes[1].trigger = .manual
    return AutomationSample(
      definition: definition, createdAt: automationAt(9, daysAgo: 3),
      passes: [
        AutomationSamplePass(nodeKey: "fetch", at: automationAt(14), outcome: fetched(items)),
        AutomationSamplePass(
          nodeKey: "judge", at: automationAt(14, 5), trigger: .now,
          outcome: judged(
            [proposal(items[0], "見積もりの件に返信", due: TaskItem.DueDate("2025-10-08"))], rows: 1)),
      ])
  }

  private static var shelfCI: AutomationSample {
    AutomationSample(
      definition: candidatesDefinition(
        "CI: main の失敗",
        fetch: commandNode(
          "fetch", "CI", .scheduled(.every(600)), script: "~/bin/ci-failures",
          coverage: .newArrivals)),
      createdAt: automationAt(9, daysAgo: 3),
      passes: round("ci", at: automationAt(14, 50), items: 1, fresh: 1))
  }

  private static var shelfPaused: AutomationSample {
    AutomationSample(
      definition: candidatesDefinition(
        "GitHub: 自分へのレビュー依頼",
        fetch: commandNode(
          "fetch", "GitHub", .scheduled(.every(3600)),
          script: "gh search prs --review-requested=@me --json url", coverage: .currentSet)),
      createdAt: automationAt(9, daysAgo: 3), paused: true,
      passes: round(
        "github", at: automationAt(9), items: 0, fresh: 0,
        failure: "gh: Not Found (HTTP 404)"))
  }

  private static func shelfDeleted(_ shared: AutomationItem) -> AutomationSample {
    AutomationSample(
      definition: candidatesDefinition(
        "GitHub: 失敗した CI",
        fetch: commandNode(
          "fetch", "GitHub Actions", .scheduled(.every(3600)), script: "~/bin/ci-runs",
          coverage: .currentSet)),
      createdAt: automationAt(9, daysAgo: 3),
      passes: [
        AutomationSamplePass(
          nodeKey: "fetch", at: automationAt(8, 45), outcome: fetched([shared])),
        AutomationSamplePass(
          nodeKey: "judge", at: automationAt(8, 46), trigger: .arrival,
          outcome: judged([proposal(shared, "main の e2e の失敗を調べる")], rows: 1)),
      ],
      deleted: true)
  }
}
