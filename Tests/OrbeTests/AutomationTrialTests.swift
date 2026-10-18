import XCTest

@testable import Orbe

/// 試走——本番の DB の写しの上で本番と同じ流しを動かし、部品の回ごとの結果を集める。番人の時計と手段の実行だけを差し替え、
/// ストアと DB と走らせ役（本番と写し）は本物で回す。手段の呼び出しは本番と試走で同じ偽物に積まれる。
///
/// 壊れると何が起きるか: 試走した項目が本番で新しい項目として流れない・候補や回の記録が本番に増える・知らせが出る。試走の
/// 結果が本番の回と違う読み方になり、AI が直した中身が本番で通らない。範囲の外の部品や副作用が走る。与えた行が流れない。
/// 試し直しても前の試走の手段が走り続ける。終わりを待つ AI が時間切れまで返らない。
final class AutomationTrialTests: OrbeTestCase {
  private static let far: TimeInterval = 86400 * 7
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  var jobs: FakeJobs!
  var store: AutomationStore!
  var runner: AutomationRunner!
  var trials: AutomationTrials!
  /// 本番の走らせ役が回を記録したと知らせた部品の鍵（窓の知らせはここから出る）。
  var recorded: [String] = []

  override func setUp() {
    jobs = FakeJobs()
    store = AutomationStore()
    let scheduler = BackgroundScheduler { _, _ in BackgroundRunHandle {} }
    scheduler.now = { [unowned self] in now }
    scheduler.calendar = { Calendar(identifier: .gregorian) }
    scheduler.arm = { _, _ in {} }
    runner = AutomationRunner(
      store: store, scheduler: scheduler, run: jobs.run,
      workspaces: { AutomationWorkspaces(listed: [], home: nil) },
      recorded: { [unowned self] in recorded.append($0.end.part) }, defined: { _ in },
      deleted: { [unowned self] in trials.discard($0) })
    runner.now = { [unowned self] in now }
    runner.calendar = { Calendar(identifier: .gregorian) }
    runner.start()
    trials = AutomationTrials(runner: runner)
  }

  override func tearDown() {
    trials = nil
    runner = nil
    store = nil
  }

  // MARK: - 部品と手段

  func part(
    _ key: String, _ trigger: AutomationPart.Trigger = .manual, from inputs: [String] = [],
    deliver: AutomationPart.Destination = .nextPart
  ) -> AutomationPart {
    DesignSceneFixtures.commandPart(key, key, trigger, from: inputs, script: key, deliver: deliver)
  }

  func fetch(_ key: String) -> AutomationPart {
    DesignSceneFixtures.commandPart(
      key, key, .scheduled(.every(Self.far)), script: key, coverage: .currentSet)
  }

  func define(_ parts: [AutomationPart]) throws -> Int {
    try runner.set(nil, AutomationDefinition(name: "自動化", notify: nil, parts: parts)).id
  }

  func calls(_ script: String) -> [Int] {
    jobs.calls.indices.filter {
      if case .command(let command, _) = jobs.calls[$0].job.work { return command.script == script }
      return false
    }
  }

  /// 最後に呼んだ `script` に標準入力で渡した行の id。
  func ids(_ script: String) -> [String] {
    guard let last = calls(script).last,
      case .command(_, let input) = jobs.calls[last].job.work
    else { return [] }
    let text = String(bytes: input.stdin ?? Data(), encoding: .utf8) ?? ""
    return text.split(separator: "\n").compactMap {
      (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["id"] as? String
    }
  }

  func finish(_ script: String, _ stdout: String, exit: Int32 = 0) {
    guard let last = calls(script).last else { return XCTFail("\(script) は呼ばれていない") }
    jobs.finish(
      last,
      BackgroundRunResult(
        commandLine: "run", startedAt: now, endedAt: now, ending: .exited(exit),
        output: .command(stdout: .init(data: Data(stdout.utf8)), stderr: .init())))
  }

  func item(_ id: String) -> String {
    #"{"id":"\#(id)","link":"https://example.com/\#(id)","body":"\#(id) の本文","#
      + #""time":"2026-10-10T09:00:00Z"}"#
  }

  func fetched(_ ids: [String]) -> String {
    ids.map(item).joined(separator: "\n")
  }

  /// 写しと試走の流れは main の後の番で進むので、条件が立つまで回す。
  func settle(
    until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    XCTAssertTrue(condition(), "条件が立たないまま時間が過ぎた", file: file, line: line)
  }

  func waitCalls(_ script: String, _ count: Int, line: UInt = #line) {
    settle(until: { calls(script).count == count }, line: line)
  }

  func ended(_ trial: AutomationTrial, line: UInt = #line) {
    settle(until: { !trial.running }, line: line)
  }

  func rows(_ trial: AutomationTrial, _ key: String) -> [String] {
    trial.passes[key]?.compactMap { pass -> [String]? in
      guard case .rows(let rows) = pass.content else { return nil }
      return rows.compactMap(AutomationPrompts.id(of:))
    }.flatMap { $0 } ?? []
  }

  // MARK: - 本番を変えない

  /// 試走の前後で本番の状態も候補も変わらず、知らせも出ない。試走で新しかった項目は、その後の本番でも新しい項目として流れる。
  func testATrialLeavesProductionAsItWasAndItsNewItemsStayNewForProduction() throws {
    let id = try define([
      fetch("gh"), part("p", from: ["gh"]),
      part("judge", from: ["p"], deliver: .taskCandidates),
    ])
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("p", #"{"id":"gh:a"}"#)
    finish("judge", #"{"propose":"gh:a","title":"A"}"#)
    let automations = store.automations
    let proposals = store.proposals
    let notices = recorded

    let trial = try trials.start(id, .init())
    waitCalls("gh", 2)
    finish("gh", fetched(["a", "b"]))
    waitCalls("p", 2)
    XCTAssertEqual(ids("p"), ["gh:b"], "写しの上の前回の出力で差分を掛ける")
    finish("p", #"{"id":"gh:b","note":"b"}"#)
    waitCalls("judge", 2)
    finish("judge", #"{"propose":"gh:b","title":"B"}"#)
    ended(trial)

    XCTAssertEqual(["gh", "p", "judge"].map { trial.state(of: $0) }, [.done, .done, .done])
    XCTAssertEqual(rows(trial, "gh"), ["gh:b"])
    XCTAssertEqual(rows(trial, "p"), ["gh:b"])
    guard case .judged(let proposed, _) = trial.passes["judge"]?.first?.content else {
      return XCTFail("判定の回に候補の案が無い")
    }
    XCTAssertEqual(proposed.map(\.title), ["B"])
    XCTAssertEqual(
      trial.passes["judge"]?.first?.run.result, .judge(proposed: 1, resolved: 0, rejected: .init()))
    XCTAssertEqual(store.automations, automations)
    XCTAssertEqual(store.proposals, proposals)
    XCTAssertEqual(recorded, notices, "試走の回は本番の知らせに届かない")

    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a", "b"]))
    XCTAssertEqual(calls("p").count, 3, "試走で見た項目も本番では新しい")
    XCTAssertEqual(ids("p"), ["gh:b"])
  }

  /// 写しの中のほかの自動化は、試走の道と同じ鍵の部品でも、溜まりに行のある「届いたら」の部品でも起こさない（写しでも手段は
  /// 本物）。手段のスクリプトは x・y で、試走する自動化の部品と見分ける。
  func testATrialDoesNotWakeOtherAutomationsInTheCopy() throws {
    let other = try define([
      DesignSceneFixtures.commandPart(
        "gh", "gh", .scheduled(.every(Self.far)), script: "x", coverage: .currentSet),
      DesignSceneFixtures.commandPart(
        "d", "d", .arrival, from: ["gh"], script: "y", deliver: .report),
    ])
    try runner.flow(other, to: .part("gh"))
    finish("x", fetched(["a"]))
    XCTAssertEqual(calls("y").count, 1, "前提: 本番の y が走っていて、取った行はまだ溜まりにある")
    let id = try define([fetch("gh"), part("d", from: ["gh"], deliver: .report)])

    let trial = try trials.start(id, .init())
    waitCalls("gh", 1)
    finish("gh", fetched([]))
    ended(trial)

    XCTAssertEqual(calls("y").count, 1)
  }

  /// 処理が `id` の無い行を出すと、試走の回は本番の回と同じ失敗の理由と外した行の記録で返る。
  func testABreachInATrialReadsTheSameAsInProduction() throws {
    let id = try define([
      fetch("gh"), part("p", from: ["gh"]), part("digest", from: ["p"], deliver: .report),
    ])
    let trial = try trials.start(id, .init())
    waitCalls("gh", 1)
    finish("gh", fetched(["a"]))
    waitCalls("p", 1)
    finish("p", #"{"note":"id を落とした"}"#)
    ended(trial)

    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("p", #"{"note":"id を落とした"}"#)

    let tried = try XCTUnwrap(trial.passes["p"]?.first?.run)
    let produced = try XCTUnwrap(store.automation(id)?.state("p").runs.first)
    XCTAssertNotNil(tried.failure)
    XCTAssertEqual(tried.failure, produced.failure)
    XCTAssertEqual(tried.breach, produced.breach)
    XCTAssertEqual(trial.passes["p"]?.first?.content, AutomationTrial.Content.none)
  }

  /// 1 つの部品が何度も回ると、回は本番の `runs` と同じく新しい順に並ぶ。
  func testRunsOfAPartAreNewestFirstAsInProduction() throws {
    let id = try define([
      fetch("gh"), fetch("backlog"),
      part("digest", .arrival, from: ["gh", "backlog"], deliver: .report),
    ])
    let trial = try trials.start(id, .init())
    waitCalls("backlog", 1)
    finish("gh", fetched(["a"]))
    waitCalls("digest", 1)
    finish("digest", "1 回目")
    finish("backlog", fetched(["b"]))
    waitCalls("digest", 2)
    finish("digest", "2 回目")
    ended(trial)

    XCTAssertEqual(
      trial.passes["digest"]?.map(\.run.result), [.report(text: "2 回目"), .report(text: "1 回目")])
    let parts = try XCTUnwrap(trial.json { _ in nil }["parts"] as? [[String: Any]])
    let runs = try XCTUnwrap(
      parts.first { $0["key"] as? String == "digest" }?["runs"] as? [[String: Any]])
    XCTAssertEqual(
      runs.map { ($0["result"] as? [String: Any])?["text"] as? String }, ["2 回目", "1 回目"])
  }

  // MARK: - 止める部品・与える行・limit

  /// 副作用は手段を起こさず、渡るはずだった行を止めた行として返す。
  func testASideEffectIsHeldWithTheRowsItWouldHaveGot() throws {
    let id = try define([fetch("gh"), part("send", .arrival, from: ["gh"], deliver: .sideEffect)])
    let trial = try trials.start(id, .init())
    waitCalls("gh", 1)
    finish("gh", fetched(["a"]))
    ended(trial)

    XCTAssertEqual(calls("send"), [])
    XCTAssertEqual(trial.state(of: "send"), .held)
    guard case .held(let held) = trial.passes["send"]?.first?.content else {
      return XCTFail("止めた行が無い")
    }
    XCTAssertEqual(held.compactMap(AutomationPrompts.id(of:)), ["gh:a"])
  }

  /// 取得の入口に与えた項目は、手段を起こさず、本番が既に見た項目でも接頭の付いた id で下流へ流れる。判定へ与えると断る。
  func testRowsGivenToAFetchFlowDownWithoutItsMethodAndAJudgeRefusesThem() throws {
    let id = try define([fetch("gh"), part("judge", from: ["gh"], deliver: .taskCandidates)])
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("judge", "")

    let trial = try trials.start(id, .init(rows: [item("a")]))
    waitCalls("judge", 2)
    XCTAssertEqual(ids("judge"), ["gh:a"])
    XCTAssertEqual(calls("gh").count, 1)
    finish("judge", "")
    ended(trial)

    XCTAssertThrowsError(
      try trials.start(id, .init(from: ["judge"], to: ["judge"], rows: [#"{"id":"x"}"#]))
    ) {
      guard case .invalid = $0 as? AutomationError else { return XCTFail("\($0)") }
    }
    XCTAssertThrowsError(try trials.start(id, .init(rows: [#"{"id":"x"}"#]))) {
      XCTAssertEqual($0 as? AutomationError, .invalid("rows: line 1: missing link"))
    }
  }

  /// 入力のある入口に与えた行は、溜まり（の写し）に届いた行として取られる。「届いたら」の入口も今すぐ動く。
  func testRowsGivenToAPartWithInputsArriveInItsInboxCopy() throws {
    let id = try define([
      fetch("gh"), part("p", .arrival, from: ["gh"]),
      part("digest", from: ["p"], deliver: .report),
    ])
    let trial = try trials.start(
      id, .init(from: ["p"], rows: [#"{"id":"x","note":"手作り"}"#]))
    waitCalls("p", 1)
    XCTAssertEqual(ids("p"), ["x"])
    XCTAssertEqual(calls("gh"), [])
    finish("p", #"{"id":"x"}"#)
    waitCalls("digest", 1)
    finish("digest", "x")
    ended(trial)
    XCTAssertEqual(store.automation(id)?.state("p").inbox, 0)
  }

  /// `limit` は取得が下流へ渡す行を先頭から絞る。
  func testALimitCutsTheRowsAFetchPassesDown() throws {
    let id = try define([
      fetch("gh"), part("p", from: ["gh"]), part("d", from: ["p"], deliver: .report),
    ])
    let trial = try trials.start(id, .init(limit: 2))
    waitCalls("gh", 1)
    finish("gh", fetched(["a", "b", "c"]))
    waitCalls("p", 1)
    XCTAssertEqual(ids("p"), ["gh:a", "gh:b"])
    finish("p", "")
    ended(trial)
    XCTAssertEqual(rows(trial, "gh"), ["gh:a", "gh:b"])
    XCTAssertEqual(trial.passes["gh"]?.first?.run.result, .fetch(fresh: 2))
  }

  // MARK: - 置き換え・消す・待つ

  /// 同じ自動化で始め直すと前の試走の手段が止まり、待っている読み手には新しい試走の終わりが返る。
  func testStartingAgainStopsTheRunningTrialAndWaitersGetTheNewOne() throws {
    let id = try define([fetch("gh"), part("d", from: ["gh"], deliver: .report)])
    _ = try trials.start(id, .init())
    waitCalls("gh", 1)
    var replies: [(AutomationTrial?, Bool)] = []
    trials.wait(id, timeout: .seconds(10)) { replies.append(((try? $0.get()), $1)) }

    let second = try trials.start(id, .init())
    XCTAssertEqual(jobs.stopped, [calls("gh")[0]])
    waitCalls("gh", 2)
    XCTAssertTrue(replies.isEmpty)
    finish("gh", fetched([]))
    ended(second)

    XCTAssertEqual(replies.count, 1)
    XCTAssertTrue(replies.first?.0 === second)
    XCTAssertEqual(replies.first?.1, false)
    XCTAssertTrue(try trials.trial(id) === second)
  }

  /// 時間切れは、その時点の試走を時間切れとして返す。
  func testWaitingPastTheTimeoutReturnsTheTrialSoFar() throws {
    let id = try define([fetch("gh"), part("d", from: ["gh"], deliver: .report)])
    _ = try trials.start(id, .init())
    var reply: (AutomationTrial?, Bool)?
    trials.wait(id, timeout: .milliseconds(30)) { reply = ((try? $0.get()), $1) }
    settle(until: { reply != nil })
    XCTAssertEqual(reply?.1, true)
    XCTAssertEqual(reply?.0?.running, true)
  }

  /// 自動化を消すと試走の手段が止まり、終わりを待つ読み手には時間切れを待たずに自動化が無いと返る。
  func testDeletingTheAutomationStopsItsTrialAndAnswersItsWaiters() throws {
    let id = try define([fetch("gh"), part("d", from: ["gh"], deliver: .report)])
    _ = try trials.start(id, .init())
    waitCalls("gh", 1)
    var reply: Result<AutomationTrial, AutomationError>?
    trials.wait(id, timeout: .seconds(10)) { result, _ in reply = result }
    try runner.delete(id)

    XCTAssertEqual(jobs.stopped, [calls("gh")[0]])
    guard case .failure(let error) = reply else { return XCTFail("待つ読み手に返っていない") }
    XCTAssertEqual(error, .automationNotFound(id))
  }
}
