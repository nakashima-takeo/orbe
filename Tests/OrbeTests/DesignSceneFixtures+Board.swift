import Foundation

@testable import Orbe

/// ボードの自動化の fixture（4 件: 前回が失敗・候補あり・新しい項目なし・止めている）。今と今日は受信タブと同じ
/// （2025-10-04 15:00）。走らせ役は `automationRunner` の取得が終わらない偽物で、本物の claude は起きない。
extension DesignSceneFixtures {
  private static func agentFetch(_ tool: String, _ request: String, _ coverage: AutomationCoverage)
    -> AutomationSource
  {
    AutomationSource(
      method: .agent(
        AutomationSourceAgent(cli: "claude", model: "haiku", tools: [tool], request: request)),
      coverage: coverage)
  }

  private static func now(_ run: AutomationRun) -> AutomationRun {
    var run = run
    run.trigger = .now
    return run
  }

  /// 判定が提案を出さず、新しい項目をすべて対応済みとして返した回。
  private static func resolvedOnly(_ run: AutomationRun) -> AutomationRun {
    var run = run
    let fresh = run.fresh ?? 0
    run.steps[run.steps.count - 1].count = fresh
    run.sink = .taskCandidates(AutomationTaskCandidatesReport(resolved: fresh))
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
        source: agentFetch(
          "mcp__slack__search_messages", "自分宛の DM とメンションを、新しい順に 50 件取る。", .newArrivals),
        trigger: .every(1800),
        instruction: "自分に頼まれたことだけをタスクにする。お礼や雑談は外す。"),
      paused: false, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(14, 45, 0),
      runs: [
        automationRun(at: at(14, 45, 0), items: 14, fresh: 3, proposed: 2),
        now(automationRun(at: at(14, 12, 0), items: 11, fresh: 0)),
        automationRun(at: at(14, 0, 0), items: 11, fresh: 1, proposed: 0),
        resolvedOnly(automationRun(at: at(13, 30, 0), items: 10, fresh: 2)),
        automationRun(
          at: at(13, 0, 0), items: 0, fresh: 0,
          failure: "the fetch agent ended: exited 1: Slack API rate limited"),
        automationRun(at: at(12, 30, 0), items: 9, fresh: 2, proposed: 1),
      ])
  }

  /// 新しい項目なしで成功（コマンド）。
  private static var boardGitHub: Automation {
    let at = automationAt
    return Automation(
      id: 2,
      definition: automationDefinition(
        "GitHub: レビュー依頼",
        source: AutomationSource(
          method: .command(
            BackgroundCommand(
              script: "gh search prs --review-requested=@me --json url,title", directory: nil)),
          coverage: .currentSet),
        trigger: .every(3600), instruction: "すべてタスクにする。期限は付けない。"),
      paused: false, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(14, 20, 0),
      runs: [
        automationRun(at: at(14, 20, 0), items: 2, fresh: 0),
        automationRun(at: at(13, 0, 0), items: 2, fresh: 1, proposed: 1),
      ])
  }

  /// 前回が失敗。
  private static var boardBacklog: Automation {
    let at = automationAt
    return Automation(
      id: 3,
      definition: automationDefinition(
        "Backlog: 担当課題",
        source: agentFetch(
          "mcp__backlog__get_issues", "自分が担当の未完了の課題を、更新の新しい順に 30 件取る。", .currentSet),
        trigger: .daily([.init(hour: 9, minute: 0), .init(hour: 13, minute: 0)]),
        instruction: "期限のある課題と、自分がコメントで頼まれた課題をタスクにする。"),
      paused: false, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(13, 0, 0),
      runs: [
        automationRun(
          at: at(13, 0, 0), items: 0, fresh: 0,
          failure: "the fetch agent ended: exited 1: Backlog の認証が切れています（401 Unauthorized）"),
        automationRun(at: at(9, 0, 0), items: 12, fresh: 1, proposed: 1),
        automationRun(at: at(13, 0, 1), items: 11, fresh: 0),
      ])
  }

  /// 止めている。
  private static var boardGmail: Automation {
    let at = automationAt
    return Automation(
      id: 4,
      definition: automationDefinition(
        "Gmail: 請求書",
        source: agentFetch(
          "mcp__gmail__search_threads", "請求書と支払い依頼のメールを、直近 3 日分取る。", .newArrivals),
        trigger: .daily([.init(hour: 10, minute: 0)]),
        instruction: "請求書の受領と支払い依頼をタスクにし、支払期日を期限にする。"),
      paused: true, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(10, 0, 1),
      runs: [automationRun(at: at(10, 0, 1), items: 3, fresh: 1, proposed: 1)])
  }

  /// まだ回っていない（作ったばかり）。
  private static var boardDraft: Automation {
    Automation(
      id: 5,
      definition: automationDefinition(
        "日報の素材",
        source: AutomationSource(
          method: .command(
            BackgroundCommand(script: "~/bin/daily-notes.sh --today", directory: "~/notes")),
          coverage: .newArrivals),
        trigger: .daily([.init(hour: 23, minute: 0)])),
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

  /// 取得の依頼文・使えるツール・コマンドと作業ディレクトリが長く、詳細がスクロールする。コマンドの前回の取得は 3 桁。回の記録は 20 件。
  static func boardAutomationLongFile() -> AutomationsFile {
    var automations = boardAutomations()
    automations[2].redefine {
      $0.source?.method = .agent(
        AutomationSourceAgent(
          cli: "claude", model: "haiku",
          tools: [
            "mcp__backlog__get_issues", "mcp__backlog__get_issue_comments",
            "mcp__backlog__get_project_list", "mcp__backlog__get_users",
            "mcp__backlog__get_notifications",
          ],
          request: (1...8).map { "\($0). 自分が担当の未完了の課題を、更新の新しい順に 30 件取る。期限の近いものを先に。" }
            .joined(separator: "\n")))
    }
    automations[2].runs += (1...17).map {
      automationRun(
        at: automationAt(13, 0, daysAgo: $0), items: 10 + $0 % 3, fresh: $0 % 2, proposed: $0 % 2
      )
    }
    automations[1].redefine {
      $0.source?.method = .command(
        BackgroundCommand(
          script: (1...6).map {
            "gh search prs --review-requested=@me --json url,title,body --limit \($0 * 10) \\"
          }
          .joined(separator: "\n") + "\n  | jq -c '.[] | {id: .url, link: .url, body: .title}'",
          directory:
            "/Users/someone/work/very/long/path/to/the/repository/that/wraps/onto/the/next/line"))
    }
    automations[1].runs[0].source?.count = 999
    return boardAutomationFile(automations)
  }
}

/// 見本『段の多い例』『一番単純な例』の自動化。段の多い例は取得元と処理 3 段（コマンド・既定のモデルの agent 2 つ）と
/// 採用・見送りの累計を持ち、一番単純な例は取得元も処理も無い。一番単純な例は、まだ定義の検証を通らない（タスク候補は取得元と
/// 段を要る）が、ボードはそのまま描く。
extension DesignSceneFixtures {
  /// 段ごとの件数を持つ回。`steps` は各段が出した数で、`stepCount` に満たなければ途中の段で止まった回。
  private static func stepsRun(
    at start: Date, source: Int, fresh: Int?, steps: [Int], proposed: Int = 0,
    failure: String? = nil
  ) -> AutomationRun {
    AutomationRun(
      startedAt: start, endedAt: start.addingTimeInterval(60), trigger: .schedule,
      source: AutomationStepReport(
        name: nil, commandLine: "~/bin/slack-dm.sh", ending: "exited 0", count: source,
        rejected: AutomationRejections()),
      fresh: fresh,
      steps: steps.enumerated().map { index, count in
        AutomationStepReport(
          name: nil, commandLine: "step \(index + 1)", ending: "exited 0", count: count,
          rejected: AutomationRejections())
      },
      sink: failure == nil
        ? .taskCandidates(AutomationTaskCandidatesReport(proposed: proposed)) : nil,
      failure: failure)
  }

  static func boardStepsExample() -> Automation {
    let at = { (minutes: Int) in
      automationAt(14, 55).addingTimeInterval(TimeInterval(-60 * minutes))
    }
    let head = [
      stepsRun(at: at(0), source: 6, fresh: 5, steps: [4, 3, 2], proposed: 2),
      stepsRun(at: at(10), source: 6, fresh: 0, steps: []),
      stepsRun(at: at(20), source: 7, fresh: 3, steps: [2, 2, 1], proposed: 1),
      stepsRun(at: at(30), source: 0, fresh: nil, steps: [], failure: "the fetch ended: exited 1"),
      stepsRun(at: at(40), source: 6, fresh: 2, steps: [0]),
      stepsRun(at: at(50), source: 6, fresh: 3, steps: [3, 0]),
    ]
    let tail = (6..<20).map { n in
      n.isMultiple(of: 3)
        ? stepsRun(at: at(n * 10), source: 6, fresh: 2, steps: [2, 1, 1], proposed: 1)
        : stepsRun(at: at(n * 10), source: 6, fresh: 0, steps: [])
    }
    return Automation(
      id: 1,
      definition: AutomationDefinition(
        name: "自分宛ての Slack DM", trigger: .every(600),
        source: AutomationSource(
          method: .command(BackgroundCommand(script: "~/bin/slack-dm.sh", directory: nil)),
          coverage: .newArrivals),
        steps: [
          AutomationStep(
            name: "bot の投稿を除く",
            method: .command(
              BackgroundCommand(script: "jq 'select(.bot_id == null)'", directory: nil))),
          AutomationStep(
            name: "雑談を除く",
            method: .agent(
              AutomationStepAgent(cli: "claude", model: nil, instruction: "挨拶やお礼だけのメッセージは除く。"))),
          AutomationStep(
            name: "依頼をタスク候補にする",
            method: .agent(
              AutomationStepAgent(
                cli: "claude", model: nil,
                instruction: "自分に何かを頼んでいるものだけを候補にする。\n期限が書かれていれば期限に入れる。"))),
        ],
        sink: .taskCandidates),
      sinkState: .taskCandidates(AutomationTaskCandidatesState(accepted: 9, dismissed: 3)),
      paused: false, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(0), runs: head + tail)
  }

  static func boardSimpleExample() -> Automation {
    let runs = (0..<20).map { daysAgo in
      AutomationRun(
        startedAt: automationAt(9, 0, daysAgo: daysAgo),
        endedAt: automationAt(9, 1, daysAgo: daysAgo), trigger: .schedule, source: nil,
        fresh: nil, steps: [], sink: .taskCandidates(AutomationTaskCandidatesReport(proposed: 1)),
        failure: nil)
    }
    return Automation(
      id: 2,
      definition: AutomationDefinition(
        name: "毎朝の PR 報告", trigger: .daily([.init(hour: 9, minute: 0)]), source: nil, steps: [],
        sink: .taskCandidates),
      paused: false, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: automationAt(9, 0), runs: runs)
  }
}
