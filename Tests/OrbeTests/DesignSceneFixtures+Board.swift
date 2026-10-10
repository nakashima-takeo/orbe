import Foundation

@testable import Orbe

/// ボードの自動追加の fixture（見本『Home』の 4 件: 前回が失敗・候補あり・新しい項目なし・止めている）。今と今日は受信タブと同じ
/// （2025-10-04 15:00）。走らせ役は `intakeRunner` の取得が終わらない偽物で、本物の claude は起きない。
extension DesignSceneFixtures {
  private static func agentFetch(_ tool: String, _ request: String, _ coverage: IntakeCoverage)
    -> IntakeFetch
  {
    IntakeFetch(
      method: .agent(
        IntakeAgentFetch(cli: "claude", model: "haiku", tools: [tool], request: request)),
      coverage: coverage)
  }

  private static func now(_ run: IntakeRun) -> IntakeRun {
    var run = run
    run.trigger = .now
    return run
  }

  private static var boardCreated: Date { intakeAt(9, 0, daysAgo: 7) }

  static func boardIntakes() -> [Intake] {
    [boardSlack, boardGitHub, boardBacklog, boardGmail]
  }

  /// 候補ありで成功（「今すぐ」の回を含む）。
  private static var boardSlack: Intake {
    let at = intakeAt
    return Intake(
      id: 1,
      definition: intakeDefinition(
        "Slack: 自分宛の DM",
        fetch: agentFetch(
          "mcp__slack__search_messages", "自分宛の DM とメンションを、新しい順に 50 件取る。", .newArrivals),
        when: .every(1800),
        instruction: "自分に頼まれたことだけをタスクにする。お礼や雑談は外す。"),
      paused: false, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(14, 45, 0),
      runs: [
        intakeRun(at: at(14, 45, 0), items: 14, newItems: 3, proposed: 2),
        now(intakeRun(at: at(14, 12, 0), items: 11, newItems: 0)),
        intakeRun(at: at(14, 0, 0), items: 11, newItems: 1, proposed: 0),
      ])
  }

  /// 新しい項目なしで成功（コマンド）。
  private static var boardGitHub: Intake {
    let at = intakeAt
    return Intake(
      id: 2,
      definition: intakeDefinition(
        "GitHub: レビュー依頼",
        fetch: IntakeFetch(
          method: .command(
            BackgroundCommand(
              script: "gh search prs --review-requested=@me --json url,title", directory: nil)),
          coverage: .currentSet),
        when: .every(3600), instruction: "すべてタスクにする。期限は付けない。"),
      paused: false, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(14, 20, 0),
      runs: [
        intakeRun(at: at(14, 20, 0), items: 2, newItems: 0),
        intakeRun(at: at(13, 0, 0), items: 2, newItems: 1, proposed: 1),
      ])
  }

  /// 前回が失敗。
  private static var boardBacklog: Intake {
    let at = intakeAt
    return Intake(
      id: 3,
      definition: intakeDefinition(
        "Backlog: 担当課題",
        fetch: agentFetch(
          "mcp__backlog__get_issues", "自分が担当の未完了の課題を、更新の新しい順に 30 件取る。", .currentSet),
        when: .daily([.init(hour: 9, minute: 0), .init(hour: 13, minute: 0)]),
        instruction: "期限のある課題と、自分がコメントで頼まれた課題をタスクにする。"),
      paused: false, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(13, 0, 0),
      runs: [
        intakeRun(
          at: at(13, 0, 0), items: 0, newItems: 0,
          failure: "the fetch agent ended: exited 1: Backlog の認証が切れています（401 Unauthorized）"),
        intakeRun(at: at(9, 0, 0), items: 12, newItems: 1, proposed: 1),
        intakeRun(at: at(13, 0, 1), items: 11, newItems: 0),
      ])
  }

  /// 止めている。
  private static var boardGmail: Intake {
    let at = intakeAt
    return Intake(
      id: 4,
      definition: intakeDefinition(
        "Gmail: 請求書",
        fetch: agentFetch(
          "mcp__gmail__search_threads", "請求書と支払い依頼のメールを、直近 3 日分取る。", .newArrivals),
        when: .daily([.init(hour: 10, minute: 0)]),
        instruction: "請求書の受領と支払い依頼をタスクにし、支払期日を期限にする。"),
      paused: true, createdAt: boardCreated, lastFetched: [], reviewAll: false,
      lastRunAt: at(10, 0, 1),
      runs: [intakeRun(at: at(10, 0, 1), items: 3, newItems: 1, proposed: 1)])
  }

  static func boardIntakeFile(_ intakes: [Intake]? = nil) -> IntakesFile {
    let intakes = intakes ?? boardIntakes()
    return IntakesFile(
      version: IntakePersistence.version, nextIntakeId: (intakes.map(\.id).max() ?? 0) + 1,
      nextProposalId: 1, intakes: intakes, proposals: [])
  }

  /// 取得の依頼文・使えるツール・コマンドと作業ディレクトリが長く、詳細がスクロールする。回の記録は 20 件。
  static func boardIntakeLongFile() -> IntakesFile {
    var intakes = boardIntakes()
    intakes[2].definition.fetch.method = .agent(
      IntakeAgentFetch(
        cli: "claude", model: "haiku",
        tools: [
          "mcp__backlog__get_issues", "mcp__backlog__get_issue_comments",
          "mcp__backlog__get_project_list", "mcp__backlog__get_users",
          "mcp__backlog__get_notifications",
        ],
        request: (1...8).map { "\($0). 自分が担当の未完了の課題を、更新の新しい順に 30 件取る。期限の近いものを先に。" }
          .joined(separator: "\n")))
    intakes[2].runs += (1...17).map {
      intakeRun(
        at: intakeAt(13, 0, daysAgo: $0), items: 10 + $0 % 3, newItems: $0 % 2, proposed: $0 % 2)
    }
    intakes[1].definition.fetch.method = .command(
      BackgroundCommand(
        script: (1...6).map {
          "gh search prs --review-requested=@me --json url,title,body --limit \($0 * 10) \\"
        }
        .joined(separator: "\n") + "\n  | jq -c '.[] | {id: .url, link: .url, body: .title}'",
        directory:
          "/Users/someone/work/very/long/path/to/the/repository/that/wraps/onto/the/next/line"))
    return boardIntakeFile(intakes)
  }
}
