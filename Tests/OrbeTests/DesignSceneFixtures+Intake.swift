import Foundation

@testable import Orbe

/// 受信タブの fixture（見本 R3Inbox.png と同じ並び）。今日はタスク画面と同じ 2025-10-04、走らせ役の今は同じ日の 15:00 に
/// 固定し、次の時刻と回の時刻を決定論にする。取得は始まっても終わらない（受信中のまま）——実物の claude は起こさない。
extension DesignSceneFixtures {
  static func intakeAt(_ hour: Int, _ minute: Int = 0, daysAgo: Int = 0) -> Date {
    let day = taskCalendar.date(byAdding: .day, value: -daysAgo, to: taskToday)!
    return taskCalendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
  }

  static var intakeNow: Date { intakeAt(15) }

  /// 番人も取得も止まった走らせ役。`file` が nil なら受信は 0 件。
  static func intakeRunner(_ file: IntakesFile?) -> IntakeRunner {
    let scheduler = BackgroundScheduler { _, _ in BackgroundRunHandle {} }
    scheduler.now = { intakeNow }
    scheduler.calendar = { taskCalendar }
    scheduler.arm = { _, _ in {} }
    let runner = IntakeRunner(
      store: IntakeStore(file: file), scheduler: scheduler,
      run: { _, _ in BackgroundRunHandle {} })
    runner.now = { intakeNow }
    runner.calendar = { taskCalendar }
    runner.start()
    return runner
  }

  static func intakeItem(_ id: String, _ body: String, at time: Date) -> IntakeItem {
    IntakeItem(id: id, link: "https://example.slack.com/archives/\(id)", body: body, time: time)
  }

  static func intakeRun(
    at start: Date, items: Int, newItems: Int, proposed: Int = 0, failure: String? = nil
  ) -> IntakeRun {
    IntakeRun(
      startedAt: start, endedAt: start.addingTimeInterval(60), trigger: .schedule,
      fetch: IntakeFetchReport(
        commandLine: "fetch", ending: failure == nil ? "exited 0" : "exited 1", items: items,
        rejected: IntakeRejections()),
      newItems: newItems,
      judge: newItems == 0 || failure != nil
        ? nil
        : IntakeJudgeReport(
          commandLine: "claude -p", ending: "exited 0", proposed: proposed, resolved: 0,
          rejected: IntakeRejections()),
      withdrawn: 0, failure: failure)
  }

  static func intakeDefinition(
    _ name: String, fetch: IntakeFetch, when: BackgroundTiming,
    instruction: String = "自分が何かを頼まれている・期限がある項目だけをタスクにする。"
  ) -> IntakeDefinition {
    IntakeDefinition(
      name: name, fetch: fetch,
      judge: IntakeJudge(cli: "claude", model: "sonnet", instruction: instruction), when: when)
  }

  /// 見本の 3 項目（見積もり・オンボーディング・週報）。
  static var intakeEstimate: IntakeItem {
    intakeItem(
      "D01-1", "@yamada · DM「見積もり、金曜までに送ってもらえますか？数字は先週の版で大丈夫です。」",
      at: intakeAt(10, 24))
  }

  static var intakeOnboarding: IntakeItem {
    intakeItem(
      "C02-7", "@tanaka · #general「@nakatake 来週のオンボーディング、環境構築の手順を一度見てもらえますか」",
      at: intakeAt(12, 41))
  }

  static var intakeWeekly: IntakeItem {
    intakeItem("C03-2", "#team-orbe「今週の進捗、金曜までに週報へお願いします」", at: intakeAt(11, 5))
  }

  /// 見本の受信 4 つ。
  static func intakeDesignIntakes() -> [Intake] {
    let (estimate, onboarding, weekly) = (intakeEstimate, intakeOnboarding, intakeWeekly)
    let seen = { (item: IntakeItem) in IntakeSeen(id: item.id, link: item.link) }
    let slack = { (script: String) in
      IntakeFetch.command(BackgroundCommand(script: script, directory: nil))
    }
    return [
      Intake(
        id: 1,
        definition: intakeDefinition(
          "Slack: 自分宛の DM・メンション", fetch: slack("~/bin/slack-mentions --since 1d"),
          when: .daily([
            .init(hour: 9, minute: 0), .init(hour: 13, minute: 0), .init(hour: 17, minute: 0),
          ])),
        paused: false, createdAt: intakeAt(9, daysAgo: 3),
        lastFetched: [seen(estimate), seen(onboarding)], reviewAll: false,
        lastRunAt: intakeAt(13),
        runs: [intakeRun(at: intakeAt(13), items: 9, newItems: 4, proposed: 2)]),
      Intake(
        id: 2,
        definition: intakeDefinition(
          "Slack: 自分の発言", fetch: slack("~/bin/slack-mine --since 1d"),
          when: .daily([.init(hour: 18, minute: 0)])),
        paused: false, createdAt: intakeAt(9, daysAgo: 3),
        lastFetched: [seen(weekly), seen(onboarding)], reviewAll: false,
        lastRunAt: intakeAt(13),
        runs: [intakeRun(at: intakeAt(13), items: 3, newItems: 1, proposed: 1)]),
      Intake(
        id: 3,
        definition: intakeDefinition(
          "Backlog: 自分が担当の未完了課題",
          fetch: .agent(
            IntakeAgentFetch(
              cli: "claude", model: "haiku", tools: ["mcp__backlog__get_issues"],
              request: "自分が担当の未完了の課題を、更新の新しい順に 30 件取る。")),
          when: .every(1800)),
        paused: false, createdAt: intakeAt(9, daysAgo: 3),
        lastFetched: [IntakeSeen(id: "ORBE-12", link: "https://example.backlog.com/view/ORBE-12")],
        reviewAll: false, lastRunAt: intakeAt(15),
        runs: [intakeRun(at: intakeAt(15), items: 14, newItems: 0)]),
      Intake(
        id: 4,
        definition: intakeDefinition(
          "GitHub: 自分へのレビュー依頼", fetch: slack("gh search prs --review-requested=@me --json url"),
          when: .every(3600)),
        paused: true, createdAt: intakeAt(9, daysAgo: 3), lastFetched: [], reviewAll: false,
        lastRunAt: intakeAt(9),
        runs: [
          intakeRun(
            at: intakeAt(9), items: 0, newItems: 0,
            failure: "the fetch ended: exited 1: gh: Not Found (HTTP 404)")
        ]),
    ]
  }

  /// 受信 4 つ（Slack の 2 つは毎日の時刻で提案あり・Backlog は 30 分ごとの軽い agent で提案なし・GitHub は止めていて
  /// 前回が失敗）と、判断待ちの提案 3 件（期限あり / なし）。Slack の 2 つは 1 件のリンクを重ねて取っている。
  static func intakeDesignFile() -> IntakesFile {
    let (estimate, onboarding, weekly) = (intakeEstimate, intakeOnboarding, intakeWeekly)
    let intakes = intakeDesignIntakes()
    let proposedAt = intakeAt(13, 1)
    let proposals = [
      IntakeProposal(
        id: 1, intakeId: 1, item: estimate, title: "見積もりを山田さんに送る",
        due: TaskItem.DueDate("2025-10-10"), proposedAt: proposedAt, state: .open),
      IntakeProposal(
        id: 2, intakeId: 1, item: onboarding, title: "オンボーディングの環境構築手順を見る", due: nil,
        proposedAt: proposedAt, state: .open),
      IntakeProposal(
        id: 3, intakeId: 2, item: weekly, title: "週報に今週の進捗を書く",
        due: TaskItem.DueDate("2025-10-10"), proposedAt: proposedAt, state: .open),
    ]
    return IntakesFile(
      version: IntakePersistence.version, nextIntakeId: 5, nextProposalId: 4, intakes: intakes,
      proposals: proposals)
  }

  /// 長いタイトル・長い本文・多い提案（棚の 1 つ目に 14 件）。
  static func intakeCrowdedFile() -> IntakesFile {
    var file = intakeDesignFile()
    let long =
      "@sato · #incident「本番のログイン直後に白画面になる件、再現手順と影響範囲をまとめて、明日の朝会までに"
      + "共有してもらえますか。顧客からの問い合わせが 3 件来ています。ログは添付のとおりで、Safari だけで起きているようです。」"
    for n in 0..<12 {
      let item = intakeItem(
        "L\(n)", n == 0 ? long : "@user\(n) · DM「確認をお願いします \(n)」", at: intakeAt(9, n))
      file.intakes[0].lastFetched.append(IntakeSeen(id: item.id, link: item.link))
      file.proposals.append(
        IntakeProposal(
          id: file.nextProposalId, intakeId: 1, item: item,
          title: n == 0
            ? "本番のログイン直後に白画面になる件の再現手順と影響範囲をまとめて朝会で共有する" : "確認の依頼 \(n) に返事をする",
          due: n.isMultiple(of: 3) ? TaskItem.DueDate("2025-10-06") : nil,
          proposedAt: intakeAt(9, 1), state: .open))
      file.nextProposalId += 1
    }
    return file
  }

  static func intakeEmptyFile() -> IntakesFile {
    IntakesFile(
      version: IntakePersistence.version, nextIntakeId: 1, nextProposalId: 1, intakes: [],
      proposals: [])
  }
}
