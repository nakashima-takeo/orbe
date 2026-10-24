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
      recorded: { [unowned self] record in
        recorded.append(
          store.automation(record.end.automationId)?.graph.node(record.end.part)?.key ?? "?")
      }, defined: { _ in },
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
    deliver: AutomationActionDef.Destination = .nextPart
  ) -> AutomationDefinition.Part {
    DesignSceneFixtures.commandPart(key, key, trigger, from: inputs, script: key, deliver: deliver)
  }

  func fetch(_ key: String) -> AutomationDefinition.Part {
    DesignSceneFixtures.commandPart(
      key, key, .scheduled(.every(Self.far)), script: key, coverage: .currentSet)
  }

  /// 下流へ渡す id（`<部品 ID>:<書かれた id>`）。
  func downstream(_ key: String, _ written: String, of id: Int) -> String {
    "\(store.part(id, key)):\(written)"
  }

  func define(_ parts: [AutomationDefinition.Part]) throws -> Int {
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
    trial.passes(key: key).compactMap { pass -> [String]? in
      guard case .rows(let rows) = pass.content else { return nil }
      return rows.compactMap(AutomationPrompts.id(of:))
    }.flatMap { $0 }
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
    finish("p", #"{"id":"\#(downstream("gh", "a", of: id))"}"#)
    finish("judge", #"{"propose":"\#(downstream("gh", "a", of: id))","title":"A"}"#)
    let automations = store.automations
    let proposals = store.proposals
    let notices = recorded

    let trial = try trials.start(id, .init())
    waitCalls("gh", 2)
    finish("gh", fetched(["a", "b"]))
    waitCalls("p", 2)
    XCTAssertEqual(ids("p"), [downstream("gh", "b", of: id)], "写しの上の読んだ位置で新しい行だけを読む")
    finish("p", #"{"id":"\#(downstream("gh", "b", of: id))","note":"b"}"#)
    waitCalls("judge", 2)
    finish("judge", #"{"propose":"\#(downstream("gh", "b", of: id))","title":"B"}"#)
    ended(trial)

    XCTAssertEqual(["gh", "p", "judge"].map { trial.state(key: $0) }, [.done, .done, .done])
    XCTAssertEqual(rows(trial, "gh"), [downstream("gh", "b", of: id)])
    XCTAssertEqual(rows(trial, "p"), [downstream("gh", "b", of: id)])
    guard case .judged(let proposed, _) = trial.passes(key: "judge").first?.content else {
      return XCTFail("判定の回に候補の案が無い")
    }
    XCTAssertEqual(proposed.map(\.title), ["B"])
    XCTAssertEqual(
      trial.passes(key: "judge").first?.run?.result,
      .judge(proposed: 1, resolved: 0, dismissed: []))
    XCTAssertEqual(store.automations, automations)
    XCTAssertEqual(store.proposals, proposals)
    XCTAssertEqual(recorded, notices, "試走の回は本番の知らせに届かない")

    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a", "b"]))
    XCTAssertEqual(calls("p").count, 3, "試走で見た項目も本番では新しい")
    XCTAssertEqual(ids("p"), [downstream("gh", "b", of: id)])
  }

  /// 写しの中のほかの自動化は、試走の道と同じ鍵の部品でも、読めば取る行のある「届いたら」の部品でも起こさない（写しでも手段は
  /// 本物）。手段のスクリプトは x・y で、試走する自動化の部品と見分ける。
  func testATrialDoesNotWakeOtherAutomationsInTheCopy() throws {
    let other = try define([
      DesignSceneFixtures.commandPart(
        "gh", "gh", .scheduled(.every(Self.far)), script: "x", coverage: .currentSet),
      DesignSceneFixtures.commandPart(
        "d", "d", .arrival, from: ["gh"], script: "y", deliver: .report),
    ])
    try runner.flow(other, to: .part(store.part(other, "gh")))
    finish("x", fetched(["a"]))
    XCTAssertEqual(calls("y").count, 1, "前提: 本番の y が走っていて、読んだ位置はまだ進んでいない")
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

    let tried = try XCTUnwrap(trial.passes(key: "p").first?.run)
    let produced = try XCTUnwrap(store.automation(id)?.state(key: "p").runs.first?.run)
    XCTAssertNotNil(tried.failure)
    XCTAssertEqual(tried.failure, produced.failure)
    XCTAssertEqual(tried.breach, produced.breach)
    XCTAssertEqual(trial.passes(key: "p").first?.content, AutomationTrial.Content.none)
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

    let parts = try XCTUnwrap(trial.json { _ in nil }["parts"] as? [[String: Any]])
    let runs = try XCTUnwrap(
      parts.first { $0["key"] as? String == "digest" }?["runs"] as? [[String: Any]])
    XCTAssertEqual(
      runs.map { ($0["result"] as? [String: Any])?["text"] as? String }, ["2 回目", "1 回目"])
  }

  /// 入力が 2 つの「届いたら」の処理が試走の中で 2 回確定しても、回ごとの結果はその回が足した行だけ（同じ時刻でも混ざらない）。
  func testEachRunOfAPartCarriesOnlyTheRowsItAdded() throws {
    let id = try define([
      fetch("gh"), fetch("backlog"), part("p", .arrival, from: ["gh", "backlog"]),
      part("d", from: ["p"], deliver: .report),
    ])
    let trial = try trials.start(id, .init(from: ["gh", "backlog"], to: ["p"]))
    waitCalls("backlog", 1)
    finish("gh", fetched(["a"]))
    waitCalls("p", 1)
    finish("p", #"{"id":"pa"}"#)
    finish("backlog", fetched(["b"]))
    waitCalls("p", 2)
    finish("p", #"{"id":"pb"}"#)
    ended(trial)

    XCTAssertEqual(trial.passes(key: "p").count, 2)
    XCTAssertEqual(
      rows(trial, "p"), [downstream("p", "pb", of: id), downstream("p", "pa", of: id)])
  }
}

extension AutomationTrial.Pass {
  /// 写しの上で確定した回（テスト）。止めた・与えた結果は nil。
  var run: AutomationPartRun? {
    if case .ran(let run, _) = self { run } else { nil }
  }

  var content: AutomationTrial.Content? {
    if case .ran(_, let content) = self { content } else { nil }
  }
}
