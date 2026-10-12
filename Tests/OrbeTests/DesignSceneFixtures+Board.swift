import Foundation

@testable import Orbe

/// ボードの自動化の fixture（4 件: 前回が失敗・候補あり・新しい項目なし・止めている）。今と今日は受信タブと同じ
/// （2025-10-04 15:00）。走らせ役は `automationRunner` の取得が終わらない偽物で、本物の claude は起きない。
extension DesignSceneFixtures {
  private static func agentFetch(_ tool: String, _ request: String, _ coverage: AutomationCoverage)
    -> AutomationFetch
  {
    AutomationFetch(
      method: .agent(
        AutomationAgentFetch(cli: "claude", model: "haiku", tools: [tool], request: request)),
      coverage: coverage)
  }

  private static func now(_ run: AutomationRun) -> AutomationRun {
    var run = run
    run.trigger = .now
    return run
  }

  /// 判定が提案を出さず、対応済みだけを返した回。
  private static func resolvedOnly(_ run: AutomationRun) -> AutomationRun {
    var run = run
    run.judge?.resolved = run.newItems
    return run
  }

  private static var boardCreated: Date { automationAt(9, 0, daysAgo: 7) }

  static func boardAutomations() -> [Automation] {
    [boardSlack, boardGitHub, boardBacklog, boardGmail]
  }

  /// 候補ありで成功（「今すぐ」の回を含む）。
  private static var boardSlack: Automation {
    let at = automationAt
    return Automation(
      id: 1,
      definition: automationDefinition(
        "Slack: 自分宛の DM",
        fetch: agentFetch(
          "mcp__slack__search_messages", "自分宛の DM とメンションを、新しい順に 50 件取る。", .newArrivals),
        when: .every(1800),
        instruction: "自分に頼まれたことだけをタスクにする。お礼や雑談は外す。"),
      paused: false, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(14, 45, 0),
      runs: [
        automationRun(at: at(14, 45, 0), items: 14, newItems: 3, proposed: 2),
        now(automationRun(at: at(14, 12, 0), items: 11, newItems: 0)),
        automationRun(at: at(14, 0, 0), items: 11, newItems: 1, proposed: 0),
        resolvedOnly(automationRun(at: at(13, 30, 0), items: 10, newItems: 2)),
        automationRun(
          at: at(13, 0, 0), items: 0, newItems: 0,
          failure: "the fetch agent ended: exited 1: Slack API rate limited"),
        automationRun(at: at(12, 30, 0), items: 9, newItems: 2, proposed: 1),
      ])
  }

  /// 新しい項目なしで成功（コマンド）。
  private static var boardGitHub: Automation {
    let at = automationAt
    return Automation(
      id: 2,
      definition: automationDefinition(
        "GitHub: レビュー依頼",
        fetch: AutomationFetch(
          method: .command(
            BackgroundCommand(
              script: "gh search prs --review-requested=@me --json url,title", directory: nil)),
          coverage: .currentSet),
        when: .every(3600), instruction: "すべてタスクにする。期限は付けない。"),
      paused: false, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(14, 20, 0),
      runs: [
        automationRun(at: at(14, 20, 0), items: 2, newItems: 0),
        automationRun(at: at(13, 0, 0), items: 2, newItems: 1, proposed: 1),
      ])
  }

  /// 前回が失敗。
  private static var boardBacklog: Automation {
    let at = automationAt
    return Automation(
      id: 3,
      definition: automationDefinition(
        "Backlog: 担当課題",
        fetch: agentFetch(
          "mcp__backlog__get_issues", "自分が担当の未完了の課題を、更新の新しい順に 30 件取る。", .currentSet),
        when: .daily([.init(hour: 9, minute: 0), .init(hour: 13, minute: 0)]),
        instruction: "期限のある課題と、自分がコメントで頼まれた課題をタスクにする。"),
      paused: false, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(13, 0, 0),
      runs: [
        automationRun(
          at: at(13, 0, 0), items: 0, newItems: 0,
          failure: "the fetch agent ended: exited 1: Backlog の認証が切れています（401 Unauthorized）"),
        automationRun(at: at(9, 0, 0), items: 12, newItems: 1, proposed: 1),
        automationRun(at: at(13, 0, 1), items: 11, newItems: 0),
      ])
  }

  /// 止めている。
  private static var boardGmail: Automation {
    let at = automationAt
    return Automation(
      id: 4,
      definition: automationDefinition(
        "Gmail: 請求書",
        fetch: agentFetch(
          "mcp__gmail__search_threads", "請求書と支払い依頼のメールを、直近 3 日分取る。", .newArrivals),
        when: .daily([.init(hour: 10, minute: 0)]),
        instruction: "請求書の受領と支払い依頼をタスクにし、支払期日を期限にする。"),
      paused: true, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(10, 0, 1),
      runs: [automationRun(at: at(10, 0, 1), items: 3, newItems: 1, proposed: 1)])
  }

  /// まだ回っていない（作ったばかり）。
  private static var boardDraft: Automation {
    Automation(
      id: 5,
      definition: automationDefinition(
        "日報の素材",
        fetch: AutomationFetch(
          method: .command(
            BackgroundCommand(script: "~/bin/daily-notes.sh --today", directory: "~/notes")),
          coverage: .newArrivals),
        when: .daily([.init(hour: 23, minute: 0)])),
      paused: false, createdAt: automationAt(14, 50), lastFetched: [], reviewAll: false,
      lastRunAt: nil, runs: [])
  }

  /// 見本と突き合わせる一覧: 4 件にまだ回っていないものを足す。
  static func boardDesignFile() -> AutomationsFile {
    boardAutomationFile(boardAutomations() + [boardDraft])
  }

  static func boardAutomationFile(_ automations: [Automation]? = nil) -> AutomationsFile {
    let automations = automations ?? boardAutomations()
    return AutomationsFile(
      version: AutomationPersistence.version,
      nextAutomationId: (automations.map(\.id).max() ?? 0) + 1,
      nextProposalId: 1, automations: automations, proposals: [])
  }

  /// 取得の依頼文・使えるツール・コマンドと作業ディレクトリが長く、詳細がスクロールする。回の記録は 20 件。
  static func boardAutomationLongFile() -> AutomationsFile {
    var automations = boardAutomations()
    automations[2].definition.fetch.method = .agent(
      AutomationAgentFetch(
        cli: "claude", model: "haiku",
        tools: [
          "mcp__backlog__get_issues", "mcp__backlog__get_issue_comments",
          "mcp__backlog__get_project_list", "mcp__backlog__get_users",
          "mcp__backlog__get_notifications",
        ],
        request: (1...8).map { "\($0). 自分が担当の未完了の課題を、更新の新しい順に 30 件取る。期限の近いものを先に。" }
          .joined(separator: "\n")))
    automations[2].runs += (1...17).map {
      automationRun(
        at: automationAt(13, 0, daysAgo: $0), items: 10 + $0 % 3, newItems: $0 % 2, proposed: $0 % 2
      )
    }
    automations[1].definition.fetch.method = .command(
      BackgroundCommand(
        script: (1...6).map {
          "gh search prs --review-requested=@me --json url,title,body --limit \($0 * 10) \\"
        }
        .joined(separator: "\n") + "\n  | jq -c '.[] | {id: .url, link: .url, body: .title}'",
        directory:
          "/Users/someone/work/very/long/path/to/the/repository/that/wraps/onto/the/next/line"))
    return boardAutomationFile(automations)
  }
}

/// 今の定義では作れない並び（処理が 3 段・取得元が無い）。読み替えの結果を直接組み、描き方だけを確かめる。値は見本の
/// 『段の多い例』『一番単純な例』。
extension DesignSceneFixtures {
  static func boardStepsExample() -> (BoardAutomationStanding, BoardAutomationSummary) {
    let (ok, none, bad) = (BoardRunTone.produced, BoardRunTone.quiet, BoardRunTone.failed)
    let standing = BoardAutomationStanding(
      id: 1, name: "自分宛ての Slack DM", paused: false, running: false,
      next: automationAt(16, 50), last: .produced)
    let summary = BoardAutomationSummary(
      output: "タスク候補", when: "10分ごと",
      nodes: [
        BoardFlowNode(role: .trigger, title: "10分ごと"),
        BoardFlowNode(
          role: .source, title: "Slack の DM", means: .command("コマンド"),
          source: "~/bin/slack-dm.sh", count: 6),
        BoardFlowNode(role: .orbe, title: "既に見たものを除く", count: 5),
        BoardFlowNode(
          role: .step(1), title: "bot の投稿を除く", means: .command("コマンド"),
          source: "jq 'select(.bot_id == null)'", count: 4),
        BoardFlowNode(
          role: .step(2), title: "雑談を除く", means: .model("haiku"), source: "挨拶やお礼だけのメッセージは除く。",
          count: 3),
        BoardFlowNode(
          role: .step(3), title: "依頼をタスク候補にする", means: .model("sonnet"),
          source: "自分に何かを頼んでいるものだけを候補にする。\n期限が書かれていれば期限に入れる。", count: 2),
        BoardFlowNode(role: .output, title: "タスク候補", count: 2),
      ],
      runs: [
        BoardRunLine(at: "16:40", result: "2件を追加", tone: ok),
        BoardRunLine(at: "16:30", result: "新着なし", tone: none),
        BoardRunLine(at: "16:20", result: "1件を追加", tone: ok),
        BoardRunLine(at: "16:10", result: "失敗：取得元が終了コード 1", tone: bad),
        BoardRunLine(at: "16:00", result: "処理 1 ですべて除外", tone: none),
        BoardRunLine(at: "15:50", result: "処理 2 ですべて除外", tone: none),
      ],
      strip: [
        ok, none, ok, none, none, ok, bad, none, ok, ok, none, none, ok, none, ok, none, none, ok,
        none, ok,
      ],
      mark: "16:40 に 2件を追加", last: "前回 今日 16:40　2件をタスク候補に追加")
    return (standing, summary)
  }

  static func boardSimpleExample() -> (BoardAutomationStanding, BoardAutomationSummary) {
    let standing = BoardAutomationStanding(
      id: 3, name: "毎朝の PR 報告", paused: false, running: false,
      next: automationAt(9, 0, daysAgo: -1), last: .produced)
    let summary = BoardAutomationSummary(
      output: "秘書に依頼", when: "平日 9:00",
      nodes: [
        BoardFlowNode(role: .trigger, title: "平日 9:00"),
        BoardFlowNode(
          role: .output, title: "秘書に依頼",
          source: "自分がレビュー待ちの PR と、自分の PR に付いたレビューをまとめて、\nSlack の #dev-me に投稿して。"),
      ],
      runs: [
        BoardRunLine(at: "今日 9:00", result: "秘書に依頼済み", tone: .produced),
        BoardRunLine(at: "10/12（月）9:00", result: "秘書に依頼済み", tone: .produced),
        BoardRunLine(at: "10/9（金）9:00", result: "秘書に依頼済み", tone: .produced),
        BoardRunLine(at: "10/8（木）9:00", result: "秘書に依頼済み", tone: .produced),
        BoardRunLine(at: "10/7（水）9:00", result: "秘書に依頼済み", tone: .produced),
      ],
      strip: Array(repeating: .produced, count: 20),
      mark: "9:00 に依頼済み", last: "前回 今日 9:00　秘書に依頼済み")
    return (standing, summary)
  }
}
