import XCTest

@testable import Orbe

/// 受信のストア——定義の検証、判定に回す新しい項目、確定の当て直し（リンク単位で 1 つの提案・人のさばきを上書きしない）、
/// どの受信の取得結果からも消えたリンクの提案を忘れる、失敗した回は何も進めない、棚に出す受信と重なり、提案をタスクにする。
///
/// 壊れると何が起きるか。同じ Slack のメッセージが 2 つの受信から二重に提案される。人が捨てた提案が次の回で「対応済み」に
/// 化ける・また提案される。取得が失敗した回に提案が一斉に消える。判定が同じ項目を回のたびに読み直す。
final class AutomationStoreTests: OrbeTestCase {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  static func definition(
    _ name: String = "Slack: 自分宛", script: String = "fetch", instruction: String = "判定して",
    coverage: AutomationCoverage = .currentSet, trigger: BackgroundTiming = .every(1800)
  ) -> AutomationDefinition {
    AutomationDefinition(
      name: name, trigger: trigger,
      source: AutomationSource(
        method: .command(BackgroundCommand(script: script, directory: nil)), coverage: coverage),
      steps: [judgeStep(instruction)], sink: .taskCandidates)
  }

  static func judgeStep(_ instruction: String = "判定して", cli: String = "claude") -> AutomationStep {
    AutomationStep(
      name: "判定",
      method: .agent(AutomationStepAgent(cli: cli, model: "haiku", instruction: instruction)))
  }

  static func agentSource(
    tools: [String] = ["mcp__slack__search"], request: String = "自分宛の DM"
  ) -> AutomationSource.Method {
    .agent(AutomationSourceAgent(cli: "claude", model: "haiku", tools: tools, request: request))
  }

  static func item(_ id: String, link: String? = nil, body: String = "本文") -> AutomationItem {
    AutomationItem(
      id: id, link: link ?? "https://example.com/\(id)", body: body,
      time: Date(timeIntervalSince1970: 1_800_000_000))
  }

  private func runRecord(failure: String? = nil) -> AutomationRun {
    Self.run(at: t0, failure: failure)
  }

  /// 取得元まで行った回の記録（確定で出力先の記録が付く）。
  static func run(at date: Date, failure: String? = nil) -> AutomationRun {
    AutomationRun(
      startedAt: date, endedAt: date, trigger: .schedule,
      source: AutomationStepReport(
        name: nil, commandLine: "fetch", ending: "exited 0", count: 0,
        rejected: AutomationRejections()),
      fresh: 0, steps: [], sink: nil, failure: failure)
  }

  /// 確定した回の出力先の記録。
  static func candidates(_ run: AutomationRun?) -> AutomationTaskCandidatesReport? {
    guard case .taskCandidates(let report) = run?.sink else { return nil }
    return report
  }

  /// 出力先タスク候補の確定を、判定の決定 `decisions` で行う（取れた項目をすべて新しい項目として取り込む）。
  static func commit(
    _ store: AutomationStore, _ id: Int, _ run: AutomationRun, fetched: [AutomationItem],
    decisions: [AutomationDecision]
  ) {
    let sink = AutomationTaskCandidates(store: store, automationId: id)
    _ = sink.admit(fetched, fetched: fetched)
    store.commit(id, run, fetched: fetched) {
      sink.commit(decisions, into: &$0, automations: $1, endedAt: run.endedAt)
    }
  }

  func store(automations count: Int = 1) throws -> AutomationStore {
    let store = AutomationStore(file: nil)
    for index in 0..<count { _ = try store.create(Self.definition("受信 \(index + 1)"), now: t0) }
    return store
  }

  /// 成功した回を確定する。`proposing` の項目に提案を出し、`resolving` のリンクを対応済みにする。
  func commit(
    _ store: AutomationStore, _ id: Int, fetched: [AutomationItem],
    proposing: [AutomationItem] = [],
    resolving: [String] = []
  ) {
    let decisions =
      proposing.map { AutomationDecision.propose(itemId: $0.id, title: "対応: \($0.id)", due: nil) }
      + resolving.map { AutomationDecision.resolve(link: $0) }
    Self.commit(store, id, runRecord(), fetched: fetched, decisions: decisions)
  }

  // MARK: - 新しい項目

  /// 枠の差分の後にタスク候補の取り込みを掛けた、段に回す項目。
  private func newItems(
    _ store: AutomationStore, _ id: Int, _ fetched: [AutomationItem]
  ) -> [AutomationItem] {
    AutomationTaskCandidates(store: store, automationId: id)
      .admit(store.unseen(of: id, in: fetched), fetched: fetched)
  }

  func testNewItemsSkipThePreviousFetchExistingProposalsAndRepeatedLinks() throws {
    let store = try store(automations: 2)
    commit(store, 1, fetched: [Self.item("a"), Self.item("b")])
    commit(store, 2, fetched: [Self.item("x")], proposing: [Self.item("x")])

    let fresh = newItems(
      store, 1,
      [
        Self.item("a"), Self.item("c"), Self.item("c2", link: "https://example.com/c"),
        Self.item("y", link: "https://example.com/x"),
      ])

    XCTAssertEqual(fresh.map(\.id), ["c"], "前回取れた id・提案のあるリンク・同じ回の 2 つ目のリンクは回さない")
  }

  /// 同じリンクでも id が新しければ（動きがあった）、提案が無い限り判定に回し直す。
  func testNewIdForAnUnproposedLinkIsJudgedAgain() throws {
    let store = try store()
    commit(store, 1, fetched: [Self.item("a")])

    XCTAssertEqual(
      newItems(store, 1, [Self.item("a2", link: "https://example.com/a")]).map(\.id), ["a2"])
  }

  func testReviewAllJudgesEverythingExceptProposedLinks() throws {
    let store = try store()
    commit(store, 1, fetched: [Self.item("a"), Self.item("b")], proposing: [Self.item("b")])
    _ = try store.replace(1, with: Self.definition("受信 1", instruction: "別の指示"))

    XCTAssertEqual(newItems(store, 1, [Self.item("a"), Self.item("b")]).map(\.id), ["a"])
    commit(store, 1, fetched: [Self.item("a"), Self.item("b")])
    XCTAssertFalse(store.automation(1)!.reviewAll, "見直した回の確定で下ろす")
  }

  // MARK: - 確定

  /// 2 つの受信が同じリンクを同時に判定しても、提案は先に確定した 1 つだけ。後の側は理由付きで捨てる。
  func testOneProposalPerLinkAcrossAutomations() throws {
    let store = try store(automations: 2)
    let shared = Self.item("m", link: "https://example.com/shared")
    let second = AutomationTaskCandidates(store: store, automationId: 2)
    XCTAssertEqual(second.admit([shared], fetched: [shared]), [shared], "まだ候補が無いので受ける")
    commit(store, 1, fetched: [shared], proposing: [shared])

    store.commit(2, runRecord(), fetched: [shared]) {
      second.commit(
        [.propose(itemId: "m", title: "二重", due: nil)], into: &$0, automations: $1,
        endedAt: self.t0)
    }
    let report = Self.candidates(store.automation(2)!.runs[0])

    XCTAssertEqual(store.proposals.count, 1)
    XCTAssertEqual(store.proposals[0].automationId, 1)
    XCTAssertEqual(report?.proposed, 0)
    XCTAssertEqual(
      report?.rejected.reasons, ["propose m: https://example.com/shared is already proposed"])
  }

  /// 判定中に人がさばいた提案は、後から届いた判定の「対応済み」で上書きしない。
  func testResolveDoesNotOverwriteAHumanDecision() throws {
    let store = try store()
    let a = Self.item("a")
    let b = Self.item("b")
    commit(store, 1, fetched: [a, b], proposing: [a, b])
    try store.dismiss(store.proposals[0].id)

    commit(store, 1, fetched: [a, b], resolving: [a.link, b.link])

    XCTAssertEqual(store.proposals.map(\.state), [.dismissed, .resolved])
    XCTAssertEqual(Self.candidates(store.automation(1)!.runs[0])?.resolved, 1)
  }

  /// どの受信の取得結果からも消えたリンクの提案は忘れる（出ていたものは下げた数に入る）。他の受信が取っている間は残る。
  func testProposalsAreForgottenOnlyWhenNoAutomationFetchesTheLink() throws {
    let store = try store(automations: 2)
    let shared = Self.item("s")
    let only = Self.item("o")
    commit(store, 1, fetched: [shared, only], proposing: [shared, only])
    commit(store, 2, fetched: [shared])

    commit(store, 1, fetched: [])

    XCTAssertEqual(store.proposals.map(\.item.link), [shared.link])
    XCTAssertEqual(Self.candidates(store.automation(1)!.runs[0])?.withdrawn, 1)
    XCTAssertEqual(store.shelf(of: store.proposals[0])?.id, 2, "提案した受信が取らなくなったら、取っている受信の棚へ")
  }

  /// 消えたリンクがまた現れたら、もう一度判定に回る。
  func testForgottenLinkIsJudgedAgainWhenItReturns() throws {
    let store = try store()
    let a = Self.item("a")
    commit(store, 1, fetched: [a], proposing: [a])
    commit(store, 1, fetched: [])

    XCTAssertEqual(newItems(store, 1, [a]).map(\.id), ["a"])
  }

  func testPausingKeepsTheFetchedLinksSoProposalsStay() throws {
    let store = try store(automations: 2)
    let a = Self.item("a")
    commit(store, 1, fetched: [a], proposing: [a])

    _ = try store.setPaused(1, true)
    commit(store, 2, fetched: [])

    XCTAssertEqual(store.proposals.count, 1)
  }

  func testDeletingAnAutomationForgetsTheLinksOnlyItFetched() throws {
    let store = try store(automations: 2)
    let a = Self.item("a")
    let b = Self.item("b")
    commit(store, 1, fetched: [a, b], proposing: [a, b])
    commit(store, 2, fetched: [b])

    try store.delete(1)

    XCTAssertEqual(store.proposals.map(\.item.link), [b.link])
  }

  /// 失敗した回は記録と最後に回った時刻だけを進め、取得済みも提案も動かさない（失敗を「0 件」と読み違えない）。
  func testFailedRunMovesOnlyTheRecordAndTheTime() throws {
    let store = try store()
    let a = Self.item("a")
    commit(store, 1, fetched: [a], proposing: [a])
    let before = store.automation(1)!

    let later = t0.addingTimeInterval(1800)
    var failed = runRecord(failure: "the fetch ended: exited 1")
    failed.startedAt = later
    store.recordFailure(of: 1, failed)

    let after = store.automation(1)!
    XCTAssertEqual(after.lastFetched, before.lastFetched)
    XCTAssertEqual(store.proposals.count, 1)
    XCTAssertEqual(after.lastRunAt, later)
    XCTAssertEqual(after.runs.first?.failure, "the fetch ended: exited 1")
  }

  func testRunRecordsKeepTheNewestTwenty() throws {
    let store = try store()
    for minute in 0..<(Automation.retainedRuns + 3) {
      var record = runRecord()
      record.startedAt = t0.addingTimeInterval(TimeInterval(minute * 60))
      store.recordFailure(of: 1, record)
    }

    let runs = store.automation(1)!.runs
    XCTAssertEqual(runs.count, Automation.retainedRuns)
    XCTAssertEqual(runs.first?.startedAt, t0.addingTimeInterval(TimeInterval(22 * 60)), "新しい順")
  }

  func testOverlapsCountSharedLinksWithEachOtherAutomation() throws {
    let store = try store(automations: 3)
    commit(store, 1, fetched: [Self.item("a"), Self.item("b"), Self.item("c")])
    commit(store, 2, fetched: [Self.item("a2", link: "https://example.com/a"), Self.item("b")])
    commit(store, 3, fetched: [Self.item("z")])

    let overlaps = store.overlaps(of: 1)
    XCTAssertEqual(overlaps.map(\.automation.id), [2])
    XCTAssertEqual(overlaps.map(\.count), [2])
  }

  // MARK: - 提案をさばく

  func testAcceptAppendsATodoTaskOnTheGivenWorkspaceAndMarksTheProposal() throws {
    let store = try store()
    let tasks = TaskStore(file: nil)
    let a = Self.item("a", body: "レビューをお願いします")
    Self.commit(
      store, 1, runRecord(), fetched: [a],
      decisions: [.propose(itemId: "a", title: "レビューする", due: TaskItem.DueDate("2026-10-12"))])

    let home = UUID()
    let task = try store.accept(store.proposals[0].id, into: tasks, workspace: home, at: .end)

    XCTAssertEqual(tasks.tasks.last, task)
    XCTAssertEqual(task.title, "レビューする")
    XCTAssertEqual(task.status, .todo)
    XCTAssertEqual(task.due?.text, "2026-10-12")
    XCTAssertEqual(task.workspace, home)
    XCTAssertEqual(task.description, "https://example.com/a\n\nレビューをお願いします")
    XCTAssertEqual(store.proposals[0].state, .accepted(taskId: task.id))
    let id = store.proposals[0].id
    XCTAssertThrowsError(try store.dismiss(id), "さばいた提案はもうさばけない") {
      XCTAssertEqual($0 as? AutomationError, .proposalNotOpen(id), "値の不正とは分けて断る")
    }
    XCTAssertThrowsError(try store.accept(id, into: tasks, workspace: home, at: .end)) {
      XCTAssertEqual($0 as? AutomationError, .proposalNotOpen(id))
    }
    XCTAssertEqual(tasks.tasks.count, 1, "断った「タスクにする」はタスクを足さない")
  }

  // MARK: - 永続

  func testStateSurvivesARestart() throws {
    let store = try store()
    let a = Self.item("a")
    commit(store, 1, fetched: [a], proposing: [a])
    _ = try store.setPaused(1, true)

    let reloaded = AutomationStore()

    XCTAssertEqual(reloaded.automations, store.automations)
    XCTAssertEqual(reloaded.proposals, store.proposals)
    XCTAssertEqual(try reloaded.create(Self.definition(), now: t0).id, 2, "採番位置も戻る")
  }

  /// 以前の Orbe が書いた intakes.json を読み替え、同じ自動化・候補として持ち、その場で automations.json を書く。旧ファイル
  /// には触らない。この fixture はこの形で凍結しておく（型の変更に合わせて書き換えない）。
  ///
  /// 壊れると何が起きるか: 更新した利用者の自動化と候補が初回起動で消える。次の起動で移行がやり直され、新しい版で起きた
  /// ことが巻き戻る。旧版の Orbe に戻すと旧ファイルが読めない。
  func testLegacyFileIsMigratedOnceAndLeftUntouched() throws {
    let saved = """
      {"version":1,"nextIntakeId":3,"nextProposalId":2,"intakes":[{"id":2,"definition":{\
      "name":"Slack: 自分宛","fetch":{"agent":"claude","model":"haiku","tools":["mcp__slack__search"],\
      "request":"DM","coverage":"newArrivals"},"judge":{"agent":"claude","model":"sonnet","instruction":"自分がやること"},\
      "when":{"dailyAt":["09:00"]}},"paused":true,"createdAt":"2027-01-15T08:00:00.000Z",\
      "lastFetched":[{"id":"m1","link":"https://example.com/m1"}],"reviewAll":false,\
      "lastRunAt":"2027-01-15T09:00:00.000Z","runs":[{"startedAt":"2027-01-15T09:00:00.000Z",\
      "endedAt":"2027-01-15T09:01:00.000Z","trigger":"schedule","fetch":{"commandLine":"claude -p",\
      "ending":"exited 0","items":1,"rejected":{"count":0,"reasons":[]}},"newItems":1,\
      "judge":{"commandLine":"claude -p","ending":"exited 0","proposed":1,"resolved":0,\
      "rejected":{"count":1,"reasons":["line 2: not JSON"]}},"withdrawn":0}]}],\
      "proposals":[{"id":1,"intakeId":2,"item":{"id":"m1","link":"https://example.com/m1",\
      "body":"返信ください","time":"2027-01-15T08:30:00.000Z"},"title":"返信する","due":"2027-01-16",\
      "proposedAt":"2027-01-15T09:01:00.000Z","state":"accepted","taskId":7}]}
      """
    let legacy = try automationsFile().deletingLastPathComponent()
      .appendingPathComponent("intakes.json")
    try Data(saved.utf8).write(to: legacy)

    let store = AutomationStore()

    let automation = try XCTUnwrap(store.automation(2), "退避せずに読む")
    XCTAssertEqual(
      automation.definition,
      AutomationDefinition(
        name: "Slack: 自分宛", trigger: .daily([.init(hour: 9, minute: 0)]),
        source: AutomationSource(
          method: .agent(
            AutomationSourceAgent(
              cli: "claude", model: "haiku", tools: ["mcp__slack__search"], request: "DM")),
          coverage: .newArrivals),
        steps: [
          AutomationStep(
            name: "判定",
            method: .agent(
              AutomationStepAgent(cli: "claude", model: "sonnet", instruction: "自分がやること")))
        ],
        sink: .taskCandidates))
    XCTAssertTrue(automation.paused)
    XCTAssertEqual(
      automation.lastFetched, [AutomationSeen(id: "m1", link: "https://example.com/m1")])
    let run = try XCTUnwrap(automation.runs.first)
    XCTAssertEqual(run.source?.count, 1)
    XCTAssertEqual(run.fresh, 1)
    XCTAssertEqual(run.steps.map(\.name), ["判定"])
    XCTAssertEqual(Self.candidates(run)?.proposed, 1)
    XCTAssertEqual(Self.candidates(run)?.rejected.reasons, ["line 2: not JSON"])
    XCTAssertEqual(automation.lastSucceededAt, run.startedAt, "失敗でない最新の回の開始時刻")
    XCTAssertEqual(store.proposals.first?.automationId, 2)
    XCTAssertEqual(store.proposals.first?.state, .accepted(taskId: 7))
    XCTAssertEqual(store.proposals.first?.due?.text, "2027-01-16")

    XCTAssertEqual(
      AutomationPersistence.load()?.automations, store.automations,
      "読み替えた時点で automations.json を書く")
    XCTAssertEqual(try Data(contentsOf: legacy), Data(saved.utf8), "旧ファイルは書き換えない")
    XCTAssertEqual(try store.create(Self.definition(), now: t0).id, 3, "採番位置も読む")
  }

  /// 使えない automations.json は退避し、その場で空の automations.json を書く——古い intakes.json へ巻き戻らない。
  func testBrokenFileIsQuarantinedAndStartsEmpty() throws {
    let url = try automationsFile()
    try Data("{\"version\":1}".utf8).write(to: url)
    try Data(
      #"{"version":1,"nextIntakeId":5,"nextProposalId":1,"intakes":[],"proposals":[]}"#.utf8
    ).write(to: url.deletingLastPathComponent().appendingPathComponent("intakes.json"))

    XCTAssertTrue(AutomationStore().automations.isEmpty)
    XCTAssertEqual(AutomationPersistence.load(), .empty, "空の automations.json が在る")
  }
}
