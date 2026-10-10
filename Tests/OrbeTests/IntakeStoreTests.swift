import XCTest

@testable import Orbe

/// 受信のストア——定義の検証、判定に回す新しい項目、確定の当て直し（リンク単位で 1 つの提案・人のさばきを上書きしない）、
/// どの受信の取得結果からも消えたリンクの提案を忘れる、失敗した回は何も進めない、棚に出す受信と重なり、提案をタスクにする。
///
/// 壊れると何が起きるか。同じ Slack のメッセージが 2 つの受信から二重に提案される。人が捨てた提案が次の回で「対応済み」に
/// 化ける・また提案される。取得が失敗した回に提案が一斉に消える。判定が同じ項目を回のたびに読み直す。
final class IntakeStoreTests: OrbeTestCase {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  static func definition(
    _ name: String = "Slack: 自分宛", script: String = "fetch", instruction: String = "判定して",
    when: BackgroundTiming = .every(1800)
  ) -> IntakeDefinition {
    IntakeDefinition(
      name: name, fetch: .command(BackgroundCommand(script: script, directory: nil)),
      judge: IntakeJudge(cli: "claude", model: "haiku", instruction: instruction), when: when)
  }

  static func item(_ id: String, link: String? = nil, body: String = "本文") -> IntakeItem {
    IntakeItem(
      id: id, link: link ?? "https://example.com/\(id)", body: body,
      time: Date(timeIntervalSince1970: 1_800_000_000))
  }

  private func runRecord(failure: String? = nil) -> IntakeRun {
    IntakeRun(
      startedAt: t0, endedAt: t0, trigger: .schedule,
      fetch: IntakeFetchReport(
        commandLine: "fetch", ending: "exited 0", items: 0, rejected: IntakeRejections()),
      newItems: 0,
      judge: IntakeJudgeReport(
        commandLine: "claude", ending: "exited 0", proposed: 0, resolved: 0,
        rejected: IntakeRejections()),
      withdrawn: 0, failure: failure)
  }

  func store(intakes count: Int = 1) throws -> IntakeStore {
    let store = IntakeStore(file: nil)
    for index in 0..<count { _ = try store.create(Self.definition("受信 \(index + 1)"), now: t0) }
    return store
  }

  /// 成功した回を確定する。`proposing` の項目に提案を出し、`resolving` のリンクを対応済みにする。
  private func commit(
    _ store: IntakeStore, _ id: Int, fetched: [IntakeItem], proposing: [IntakeItem] = [],
    resolving: [String] = []
  ) {
    let decisions =
      proposing.map { IntakeDecision.propose(itemId: $0.id, title: "対応: \($0.id)", due: nil) }
      + resolving.map { IntakeDecision.resolve(link: $0) }
    store.commit(
      id, runRecord(), fetched: fetched, judged: proposing, decisions: decisions)
  }

  // MARK: - 新しい項目

  func testNewItemsSkipThePreviousFetchExistingProposalsAndRepeatedLinks() throws {
    let store = try store(intakes: 2)
    commit(store, 1, fetched: [Self.item("a"), Self.item("b")])
    commit(store, 2, fetched: [Self.item("x")], proposing: [Self.item("x")])

    let fresh = store.newItems(
      of: 1,
      in: [
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
      store.newItems(of: 1, in: [Self.item("a2", link: "https://example.com/a")]).map(\.id), ["a2"])
  }

  func testReviewAllJudgesEverythingExceptProposedLinks() throws {
    let store = try store()
    commit(store, 1, fetched: [Self.item("a"), Self.item("b")], proposing: [Self.item("b")])
    var changed = Self.definition("受信 1")
    changed.judge.instruction = "別の指示"
    _ = try store.replace(1, with: changed)

    XCTAssertEqual(store.newItems(of: 1, in: [Self.item("a"), Self.item("b")]).map(\.id), ["a"])
    commit(store, 1, fetched: [Self.item("a"), Self.item("b")])
    XCTAssertFalse(store.intake(1)!.reviewAll, "見直した回の確定で下ろす")
  }

  // MARK: - 確定

  /// 2 つの受信が同じリンクを同時に判定しても、提案は先に確定した 1 つだけ。後の側は理由付きで捨てる。
  func testOneProposalPerLinkAcrossIntakes() throws {
    let store = try store(intakes: 2)
    let shared = Self.item("m", link: "https://example.com/shared")
    commit(store, 1, fetched: [shared], proposing: [shared])

    var record = runRecord()
    store.commit(
      2, record, fetched: [shared], judged: [shared],
      decisions: [.propose(itemId: "m", title: "二重", due: nil)])
    record = store.intake(2)!.runs[0]

    XCTAssertEqual(store.proposals.count, 1)
    XCTAssertEqual(store.proposals[0].intakeId, 1)
    XCTAssertEqual(record.judge?.proposed, 0)
    XCTAssertEqual(
      record.judge?.rejected.reasons, ["propose m: https://example.com/shared is already proposed"])
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
    XCTAssertEqual(store.intake(1)!.runs[0].judge?.resolved, 1)
  }

  /// どの受信の取得結果からも消えたリンクの提案は忘れる（出ていたものは下げた数に入る）。他の受信が取っている間は残る。
  func testProposalsAreForgottenOnlyWhenNoIntakeFetchesTheLink() throws {
    let store = try store(intakes: 2)
    let shared = Self.item("s")
    let only = Self.item("o")
    commit(store, 1, fetched: [shared, only], proposing: [shared, only])
    commit(store, 2, fetched: [shared])

    commit(store, 1, fetched: [])

    XCTAssertEqual(store.proposals.map(\.item.link), [shared.link])
    XCTAssertEqual(store.intake(1)!.runs[0].withdrawn, 1)
    XCTAssertEqual(store.shelf(of: store.proposals[0])?.id, 2, "提案した受信が取らなくなったら、取っている受信の棚へ")
  }

  /// 消えたリンクがまた現れたら、もう一度判定に回る。
  func testForgottenLinkIsJudgedAgainWhenItReturns() throws {
    let store = try store()
    let a = Self.item("a")
    commit(store, 1, fetched: [a], proposing: [a])
    commit(store, 1, fetched: [])

    XCTAssertEqual(store.newItems(of: 1, in: [a]).map(\.id), ["a"])
  }

  func testPausingKeepsTheFetchedLinksSoProposalsStay() throws {
    let store = try store(intakes: 2)
    let a = Self.item("a")
    commit(store, 1, fetched: [a], proposing: [a])

    _ = try store.setPaused(1, true)
    commit(store, 2, fetched: [])

    XCTAssertEqual(store.proposals.count, 1)
  }

  func testDeletingAnIntakeForgetsTheLinksOnlyItFetched() throws {
    let store = try store(intakes: 2)
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
    let before = store.intake(1)!

    let later = t0.addingTimeInterval(1800)
    var failed = runRecord(failure: "the fetch ended: exited 1")
    failed.startedAt = later
    store.recordFailure(of: 1, failed)

    let after = store.intake(1)!
    XCTAssertEqual(after.lastFetched, before.lastFetched)
    XCTAssertEqual(store.proposals.count, 1)
    XCTAssertEqual(after.lastRunAt, later)
    XCTAssertEqual(after.runs.first?.failure, "the fetch ended: exited 1")
  }

  func testRunRecordsKeepTheNewestTwenty() throws {
    let store = try store()
    for minute in 0..<(Intake.retainedRuns + 3) {
      var record = runRecord()
      record.startedAt = t0.addingTimeInterval(TimeInterval(minute * 60))
      store.recordFailure(of: 1, record)
    }

    let runs = store.intake(1)!.runs
    XCTAssertEqual(runs.count, Intake.retainedRuns)
    XCTAssertEqual(runs.first?.startedAt, t0.addingTimeInterval(TimeInterval(22 * 60)), "新しい順")
  }

  func testOverlapsCountSharedLinksWithEachOtherIntake() throws {
    let store = try store(intakes: 3)
    commit(store, 1, fetched: [Self.item("a"), Self.item("b"), Self.item("c")])
    commit(store, 2, fetched: [Self.item("a2", link: "https://example.com/a"), Self.item("b")])
    commit(store, 3, fetched: [Self.item("z")])

    let overlaps = store.overlaps(of: 1)
    XCTAssertEqual(overlaps.map(\.intake.id), [2])
    XCTAssertEqual(overlaps.map(\.count), [2])
  }

  // MARK: - 提案をさばく

  func testAcceptAppendsATodoTaskOnTheGivenWorkspaceAndMarksTheProposal() throws {
    let store = try store()
    let tasks = TaskStore(file: nil)
    let a = Self.item("a", body: "レビューをお願いします")
    store.commit(
      1, runRecord(), fetched: [a], judged: [a],
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
      XCTAssertEqual($0 as? IntakeError, .proposalNotOpen(id), "値の不正とは分けて断る")
    }
    XCTAssertThrowsError(try store.accept(id, into: tasks, workspace: home, at: .end)) {
      XCTAssertEqual($0 as? IntakeError, .proposalNotOpen(id))
    }
    XCTAssertEqual(tasks.tasks.count, 1, "断った「タスクにする」はタスクを足さない")
  }

  // MARK: - 永続

  func testStateSurvivesARestart() throws {
    let store = try store()
    let a = Self.item("a")
    commit(store, 1, fetched: [a], proposing: [a])
    _ = try store.setPaused(1, true)

    let reloaded = IntakeStore()

    XCTAssertEqual(reloaded.intakes, store.intakes)
    XCTAssertEqual(reloaded.proposals, store.proposals)
    XCTAssertEqual(try reloaded.create(Self.definition(), now: t0).id, 2, "採番位置も戻る")
  }

  /// 以前の Orbe が書いた intakes.json を読み戻せる。この fixture はこの形で凍結しておく（型の変更に合わせて書き換えない）。
  ///
  /// 壊れると何が起きるか: 回の記録や提案の Swift の名前を変える・既定値付きの必須フィールドを足すと、保存の語が黙って
  /// 変わり、更新した利用者の intakes.json が初回起動で丸ごと退避されて、AI と人が作った受信と提案が消える。
  func testFileWrittenByThisVersionLoads() throws {
    let saved = """
      {"version":1,"nextIntakeId":3,"nextProposalId":2,"intakes":[{"id":2,"definition":{\
      "name":"Slack: 自分宛","fetch":{"agent":"claude","model":"haiku","tools":["mcp__slack__search"],\
      "request":"DM"},"judge":{"agent":"claude","model":"sonnet","instruction":"自分がやること"},\
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
    try Data(saved.utf8).write(to: try intakesFile())

    let store = IntakeStore()

    let intake = try XCTUnwrap(store.intake(2), "退避せずに読む")
    XCTAssertEqual(
      intake.definition,
      IntakeDefinition(
        name: "Slack: 自分宛",
        fetch: .agent(
          IntakeAgentFetch(
            cli: "claude", model: "haiku", tools: ["mcp__slack__search"], request: "DM")),
        judge: IntakeJudge(cli: "claude", model: "sonnet", instruction: "自分がやること"),
        when: .daily([.init(hour: 9, minute: 0)])))
    XCTAssertTrue(intake.paused)
    XCTAssertEqual(intake.lastFetched, [IntakeSeen(id: "m1", link: "https://example.com/m1")])
    XCTAssertEqual(intake.runs.first?.newItems, 1)
    XCTAssertEqual(intake.runs.first?.judge?.rejected.reasons, ["line 2: not JSON"])
    XCTAssertEqual(store.proposals.first?.state, .accepted(taskId: 7))
    XCTAssertEqual(store.proposals.first?.due?.text, "2027-01-16")
    XCTAssertEqual(try store.create(Self.definition(), now: t0).id, 3, "採番位置も読む")
  }

  func testBrokenFileIsQuarantinedAndStartsEmpty() throws {
    let url = try intakesFile()
    try Data("{\"version\":1}".utf8).write(to: url)

    XCTAssertTrue(IntakeStore().intakes.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "使えない原本は退避する")
  }
}
