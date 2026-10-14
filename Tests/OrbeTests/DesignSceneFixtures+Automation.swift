import Foundation

@testable import Orbe

extension Automation {
  /// 定義の一部を書き換える（出力先ごとの状態は `redefine` が合わせる）。
  mutating func redefine(_ edit: (inout AutomationDefinition) -> Void) {
    var definition = definition
    edit(&definition)
    redefine(definition)
  }
}

/// 提案タブの fixture（見本 R3Inbox.png と同じ並び）。今日はタスク画面と同じ 2025-10-04、走らせ役の今は同じ日の 15:00 に
/// 固定し、次の時刻と回の時刻を決定論にする。取得は始まっても終わらない（実行中のまま）——実物の claude は起こさない。
extension DesignSceneFixtures {
  static func automationAt(_ hour: Int, _ minute: Int = 0, daysAgo: Int = 0) -> Date {
    let day = taskCalendar.date(byAdding: .day, value: -daysAgo, to: taskToday)!
    return taskCalendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
  }

  static var automationNow: Date { automationAt(15) }

  /// 番人も取得も止まった走らせ役。`file` が nil なら受信は 0 件。
  static func automationRunner(_ file: AutomationsFile?) -> AutomationRunner {
    let scheduler = BackgroundScheduler { _, _ in BackgroundRunHandle {} }
    scheduler.now = { automationNow }
    scheduler.calendar = { taskCalendar }
    scheduler.arm = { _, _ in {} }
    let runner = AutomationRunner(
      store: AutomationStore(file: file), scheduler: scheduler,
      run: { _, _ in BackgroundRunHandle {} },
      workspaces: { AutomationWorkspaces(listed: [], home: nil) }, recorded: { _ in },
      defined: { _ in },
      deleted: { _ in })
    runner.now = { automationNow }
    runner.calendar = { taskCalendar }
    runner.start()
    return runner
  }

  static func automationItem(_ id: String, _ body: String, at time: Date) -> AutomationItem {
    AutomationItem(id: id, link: "https://example.slack.com/archives/\(id)", body: body, time: time)
  }

  static func automationRun(
    at start: Date, items: Int, fresh: Int, proposed: Int = 0, failure: String? = nil
  ) -> AutomationRun {
    AutomationRun(
      startedAt: start, endedAt: start.addingTimeInterval(60), trigger: .schedule,
      source: AutomationStepReport(
        name: nil, commandLine: "fetch", ending: failure == nil ? "exited 0" : "exited 1",
        count: items, rejected: AutomationRejections()),
      fresh: failure == nil ? fresh : nil,
      steps: fresh == 0 || failure != nil
        ? []
        : [
          AutomationStepReport(
            name: "判定", commandLine: "claude -p", ending: "exited 0", count: proposed,
            rejected: AutomationRejections())
        ],
      lastStepCountedBySink: fresh != 0 && failure == nil,
      sink: failure == nil
        ? .taskCandidates(AutomationTaskCandidatesReport(proposed: proposed)) : nil,
      failure: failure)
  }

  /// 見本の cron のいつ。見本には正しい式だけを書く。
  static func cron(_ expression: String) -> BackgroundTiming {
    do {
      return .cron(try BackgroundCron(expression))
    } catch {
      preconditionFailure("\(expression): \(error.message)")
    }
  }

  static func automationDefinition(
    _ name: String, source: AutomationSource, trigger: BackgroundTiming,
    instruction: String = "自分が何かを頼まれている・期限がある項目だけをタスクにする。"
  ) -> AutomationDefinition {
    AutomationDefinition(
      name: name, trigger: trigger, source: source,
      steps: [
        AutomationStep(
          name: "判定",
          method: .agent(
            AutomationStepAgent(cli: "claude", model: "sonnet", instruction: instruction)))
      ],
      sink: .taskCandidates)
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

  /// 見本の受信 4 つ。
  static func automationDesignAutomations() -> [Automation] {
    let (estimate, onboarding, weekly) = (
      automationEstimate, automationOnboarding, automationWeekly
    )
    let seen = { (item: AutomationItem) in AutomationSeen(id: item.id, link: item.link) }
    let command = { (script: String, coverage: AutomationCoverage) in
      AutomationSource(
        method: .command(BackgroundCommand(script: script, directory: nil)), coverage: coverage)
    }
    return [
      Automation(
        id: 1,
        definition: automationDefinition(
          "Slack: 自分宛の DM・メンション", source: command("~/bin/slack-mentions --since 1d", .newArrivals),
          trigger: cron("0 9,13,17 * * *")),
        paused: false, createdAt: automationAt(9, daysAgo: 3),
        lastFetched: [seen(estimate), seen(onboarding)], reviewAll: false,
        lastRunAt: automationAt(13),
        runs: [automationRun(at: automationAt(13), items: 9, fresh: 4, proposed: 2)]),
      Automation(
        id: 2,
        definition: automationDefinition(
          "Slack: 自分の発言", source: command("~/bin/slack-mine --since 1d", .newArrivals),
          trigger: cron("0 18 * * *")),
        paused: false, createdAt: automationAt(9, daysAgo: 3),
        lastFetched: [seen(weekly), seen(onboarding)], reviewAll: false,
        lastRunAt: automationAt(13),
        runs: [automationRun(at: automationAt(13), items: 3, fresh: 1, proposed: 1)]),
      Automation(
        id: 3,
        definition: automationDefinition(
          "Backlog: 自分が担当の未完了課題",
          source: AutomationSource(
            method: .agent(
              AutomationSourceAgent(
                cli: "claude", model: "haiku", tools: ["mcp__backlog__get_issues"],
                request: "自分が担当の未完了の課題を、更新の新しい順に 30 件取る。")),
            coverage: .currentSet),
          trigger: .every(1800)),
        paused: false, createdAt: automationAt(9, daysAgo: 3),
        lastFetched: [
          AutomationSeen(id: "ORBE-12", link: "https://example.backlog.com/view/ORBE-12")
        ],
        reviewAll: false, lastRunAt: automationAt(15),
        runs: [automationRun(at: automationAt(15), items: 14, fresh: 0)]),
      Automation(
        id: 4,
        definition: automationDefinition(
          "GitHub: 自分へのレビュー依頼",
          source: command("gh search prs --review-requested=@me --json url", .currentSet),
          trigger: .every(3600)),
        paused: true, createdAt: automationAt(9, daysAgo: 3), lastFetched: [], reviewAll: false,
        lastRunAt: automationAt(9),
        runs: [
          automationRun(
            at: automationAt(9), items: 0, fresh: 0,
            failure: "the fetch ended: exited 1: gh: Not Found (HTTP 404)")
        ]),
    ]
  }

  /// 受信 4 つ（Slack の 2 つは cron の時刻で提案あり・Backlog は 30 分ごとの軽い agent で提案なし・GitHub は止めていて
  /// 前回が失敗）と、判断待ちの提案 3 件（期限あり / なし、付け先が orbe / Home / work）。Slack の 2 つは 1 件のリンクを
  /// 重ねて取っている。
  static func automationDesignFile() -> AutomationsFile {
    let (estimate, onboarding, weekly) = (
      automationEstimate, automationOnboarding, automationWeekly
    )
    let automations = automationDesignAutomations()
    let proposedAt = automationAt(13, 1)
    let proposals = [
      AutomationProposal(
        id: 1, automationId: 1, item: estimate, title: "見積もりを山田さんに送る",
        due: TaskItem.DueDate("2025-10-10"), workspace: taskWorkspaces.all[0].id,
        proposedAt: proposedAt, state: .open),
      AutomationProposal(
        id: 2, automationId: 1, item: onboarding, title: "オンボーディングの環境構築手順を見る", due: nil,
        workspace: nil, proposedAt: proposedAt, state: .open),
      AutomationProposal(
        id: 3, automationId: 2, item: weekly, title: "週報に今週の進捗を書く",
        due: TaskItem.DueDate("2025-10-10"), workspace: taskWorkspaces.all[1].id,
        proposedAt: proposedAt, state: .open),
    ]
    return AutomationsFile(
      version: AutomationPersistence.version, nextAutomationId: 5, nextProposalId: 4,
      automations: automations,
      proposals: proposals)
  }

  /// 長いタイトル・長い本文・多い提案（棚の 1 つ目に 14 件）。
  static func automationCrowdedFile() -> AutomationsFile {
    var file = automationDesignFile()
    let long =
      "@sato · #incident「本番のログイン直後に白画面になる件、再現手順と影響範囲をまとめて、明日の朝会までに"
      + "共有してもらえますか。顧客からの問い合わせが 3 件来ています。ログは添付のとおりで、Safari だけで起きているようです。」"
    for n in 0..<12 {
      let item = automationItem(
        "L\(n)", n == 0 ? long : "@user\(n) · DM「確認をお願いします \(n)」", at: automationAt(9, n))
      file.automations[0].lastFetched.append(AutomationSeen(id: item.id, link: item.link))
      file.proposals.append(
        AutomationProposal(
          id: file.nextProposalId, automationId: 1, item: item,
          title: n == 0
            ? "本番のログイン直後に白画面になる件の再現手順と影響範囲をまとめて朝会で共有する" : "確認の依頼 \(n) に返事をする",
          due: n.isMultiple(of: 3) ? TaskItem.DueDate("2025-10-06") : nil, workspace: nil,
          proposedAt: automationAt(9, 1), state: .open))
      file.nextProposalId += 1
    }
    return file
  }

  static func automationEmptyFile() -> AutomationsFile {
    AutomationsFile(
      version: AutomationPersistence.version, nextAutomationId: 1, nextProposalId: 1,
      automations: [],
      proposals: [])
  }

  /// 受信の中身を行数で切らないことを見る見本: Backlog（3）の取得役に長い依頼文と多くのツール・長い判定の指示文、
  /// Slack（1）に長い取得のコマンドと作業ディレクトリ。
  static func automationLongFile() -> AutomationsFile {
    var long = automationDesignFile()
    if let agentIndex = long.automations.firstIndex(where: { $0.id == 3 }) {
      long.automations[agentIndex].redefine {
        $0.source?.method = .agent(
          AutomationSourceAgent(
            cli: "claude", model: "haiku",
            tools: [
              "mcp__backlog__get_issues", "mcp__backlog__get_issue_comments",
              "mcp__backlog__get_project_list", "mcp__backlog__get_users",
              "mcp__backlog__get_notifications", "mcp__backlog__get_wiki_pages",
            ],
            request: (1...9).map { "\($0). 自分が担当の未完了の課題を、更新の新しい順に 30 件取る。期限の近いものを先に。" }
              .joined(separator: "\n")))
        $0.steps[0].method = .agent(
          AutomationStepAgent(
            cli: "claude", model: "sonnet",
            instruction: (1...8).map { "\($0). 今日中に自分が手を動かす必要があるものだけをタスクにする。" }
              .joined(separator: "\n")))
      }
    }
    if let commandIndex = long.automations.firstIndex(where: { $0.id == 1 }) {
      long.automations[commandIndex].redefine {
        $0.source?.method = .command(
          BackgroundCommand(
            script: (1...8).map {
              "gh search prs --review-requested=@me --json url,title,body --limit \($0 * 10) \\"
            }
            .joined(separator: "\n") + "\n  | jq -c '.[] | {id: .url, link: .url, body: .title}'",
            directory:
              "/Users/someone/work/very/long/path/to/the/repository/that/wraps/onto/the/next/line"))
      }
    }
    return long
  }
}
