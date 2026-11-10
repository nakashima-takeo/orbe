import XCTest

@testable import Orbe

/// 試走——本番の DB の写しの上で本番と同じ流しを動かし、ノードの回ごとの結果を集める。番人の時計と手段の実行だけを差し替え、
/// ストアと DB と走らせ役（本番と写し）は本物で回す。手段の呼び出しは本番と試走で同じ偽物に積まれる。
///
/// 壊れると何が起きるか: 試走した項目が本番で新しい項目として流れない・候補や回の記録が本番に増える・知らせが出る。試走の
/// 結果が本番の回と違う読み方になり、AI が直した中身が本番で通らない。範囲の外のノードや副作用が走る。与えた行が流れない。
/// 試し直しても前の試走の手段が走り続ける。終わりを待つ AI が時間切れまで返らない。
final class AutomationTrialTests: OrbeTestCase {
  private static let far: TimeInterval = 86400 * 7
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  var jobs: FakeJobs!
  var store: AutomationStore!
  var runner: AutomationRunner!
  var trials: AutomationTrials!
  /// 本番の走らせ役が回を記録したと知らせたノードの鍵（窓の知らせはここから出る）。
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
      workspaces: { AutomationWorkspaces(all: [], home: nil) },
      recorded: { [unowned self] record in
        recorded.append(
          store.automation(record.end.automationId)?.graph.node(record.end.nodeId)?.key ?? "?")
      }, defined: { _, _ in },
      deleted: { [unowned self] id, _ in trials.discard(id) })
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

  // MARK: - ノードと手段

  func definitionNode(
    _ key: String, _ trigger: AutomationNode.Trigger = .manual, from inputs: [String] = [],
    deliver: AutomationActionDef.Destination = .nextNode
  ) -> AutomationDefinition.Node {
    DesignSceneFixtures.commandNode(key, key, trigger, from: inputs, script: key, deliver: deliver)
  }

  func fetch(_ key: String) -> AutomationDefinition.Node {
    DesignSceneFixtures.commandNode(
      key, key, .scheduled(.every(Self.far)), script: key, coverage: .currentSet)
  }

  /// 下流へ渡す id（`<ノード ID>:<書かれた id>`）。
  func downstream(_ key: String, _ written: String, of id: Int) -> String {
    "\(store.nodeId(id, key)):\(written)"
  }

  func definition(_ definitionNodes: [AutomationDefinition.Node]) -> AutomationDefinition {
    AutomationDefinition(name: "自動化", notify: nil, nodes: definitionNodes)
  }

  /// 書く前の定義の試走の対象（本番のストアで確かめる）。
  func unsaved(_ write: AutomationStore.Write) throws -> AutomationTrial.Target {
    let checked = try store.check(write)
    return .unsaved(checked.write, nodes: checked.nodes)
  }

  func define(_ definitionNodes: [AutomationDefinition.Node]) throws -> Int {
    try runner.set(nil, definition(definitionNodes)).id
  }

  func calls(_ script: String) -> [Int] {
    jobs.calls.indices.filter { self.script(at: $0) == script }
  }

  /// `index` 番目に呼んだ手段のスクリプト。
  func script(at index: Int) -> String? {
    guard case .command(let command, _) = jobs.calls[index].job.work else { return nil }
    return command.script
  }

  /// 最後に呼んだ `script` に標準入力で渡した行の id。
  func ids(_ script: String) -> [String] {
    guard let last = calls(script).last else { return [] }
    return ids(at: last)
  }

  /// `index` 番目の呼び出しに標準入力で渡した行の id。
  func ids(at index: Int) -> [String] {
    guard case .command(_, let input) = jobs.calls[index].job.work else { return [] }
    let text = String(bytes: input.stdin ?? Data(), encoding: .utf8) ?? ""
    return text.split(separator: "\n").compactMap {
      (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["id"] as? String
    }
  }

  func finish(_ script: String, _ stdout: String, exit: Int32 = 0) {
    guard let last = calls(script).last else { return XCTFail("\(script) は呼ばれていない") }
    finish(at: last, stdout, exit: exit)
  }

  func finish(at index: Int, _ stdout: String, exit: Int32 = 0) {
    jobs.finish(
      index,
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
      fetch("gh"), definitionNode("p", from: ["gh"]),
      definitionNode("judge", from: ["p"], deliver: .taskCandidates),
    ])
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("p", #"{"id":"\#(downstream("gh", "a", of: id))","link":"https://example.com/a"}"#)
    finish("judge", #"{"propose":"\#(downstream("gh", "a", of: id))","title":"A"}"#)
    let automations = store.automations
    let proposals = store.proposals
    let notices = recorded

    let trial = try trials.start(.saved(id), .init())
    waitCalls("gh", 2)
    finish("gh", fetched(["a", "b"]))
    waitCalls("p", 2)
    XCTAssertEqual(ids("p"), [downstream("gh", "b", of: id)], "写しの上の読んだ位置で新しい行だけを読む")
    finish(
      "p", #"{"id":"\#(downstream("gh", "b", of: id))","note":"b","link":"https://example.com/b"}"#)
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

  /// 写しの中のほかの自動化は、試走の道と同じ鍵のノードでも、読めば取る行のある「届いたら」のノードでも起こさない（写しでも手段は
  /// 本物）。手段のスクリプトは x・y で、試走する自動化のノードと見分ける。
  func testATrialDoesNotWakeOtherAutomationsInTheCopy() throws {
    let other = try define([
      DesignSceneFixtures.commandNode(
        "gh", "gh", .scheduled(.every(Self.far)), script: "x", coverage: .currentSet),
      DesignSceneFixtures.commandNode(
        "d", "d", .arrival, from: ["gh"], script: "y", deliver: .report),
    ])
    try runner.flow(other, to: .node(store.nodeId(other, "gh")))
    finish("x", fetched(["a"]))
    XCTAssertEqual(calls("y").count, 1, "前提: 本番の y が走っていて、読んだ位置はまだ進んでいない")
    let id = try define([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)])

    let trial = try trials.start(.saved(id), .init())
    waitCalls("gh", 1)
    finish("gh", fetched([]))
    ended(trial)

    XCTAssertEqual(calls("y").count, 1)
  }

  /// 試走の間、道のノードは予定の時刻を過ぎていても写しの上で予定では回らず、流しの順に 1 回だけ動く。
  func testNodesOnThePathDoNotRunOnTheirScheduleInTheCopy() throws {
    // 写しの番人は壁時計で数えるので、1 時間前に足した 1 分ごとのノードの予定は写しの上で過ぎている。判定には前からの読めば取る
    // 行を持たせる（予定で回れば、上流を待たずにそれを読む）。
    now = Date()
    let added = now.addingTimeInterval(-3600)
    let id = try store.create(
      AutomationDefinition(
        name: "自動化", notify: nil,
        nodes: [
          fetch("gh"),
          definitionNode("judge", .scheduled(.every(60)), from: ["gh"], deliver: .taskCandidates),
        ]), now: added
    ).id
    try store.record(
      id, nodeKey: "gh", at: added,
      outcome: DesignSceneFixtures.fetched([
        AutomationItem(id: "a", link: "https://example.com/a", body: "a", time: added)
      ]))

    let trial = try trials.start(.saved(id), .init())
    waitCalls("gh", 1)
    XCTAssertEqual(calls("judge"), [], "上流が終わる前に予定で回らない")
    finish("gh", fetched(["a", "b"]))
    waitCalls("judge", 1)
    XCTAssertEqual(ids("judge"), [downstream("gh", "a", of: id), downstream("gh", "b", of: id)])
    finish("judge", "")
    ended(trial)

    XCTAssertEqual(calls("judge").count, 1)
  }

  /// 処理が `id` の無い行を出すと、試走の回は本番の回と同じ失敗の理由と外した行の記録で返る。
  func testABreachInATrialReadsTheSameAsInProduction() throws {
    let id = try define([
      fetch("gh"), definitionNode("p", from: ["gh"]),
      definitionNode("digest", from: ["p"], deliver: .report),
    ])
    let trial = try trials.start(.saved(id), .init())
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

  /// 1 つのノードが何度も回ると、回は本番の `runs` と同じく新しい順に並ぶ。
  func testRunsOfANodeAreNewestFirstAsInProduction() throws {
    let id = try define([
      fetch("gh"), fetch("backlog"),
      definitionNode("digest", .arrival, from: ["gh", "backlog"], deliver: .report),
    ])
    let trial = try trials.start(.saved(id), .init())
    waitCalls("backlog", 1)
    finish("gh", fetched(["a"]))
    waitCalls("digest", 1)
    finish("digest", "1 回目")
    finish("backlog", fetched(["b"]))
    waitCalls("digest", 2)
    finish("digest", "2 回目")
    ended(trial)

    let nodes = try XCTUnwrap(trial.json { _ in nil }["nodes"] as? [[String: Any]])
    let runs = try XCTUnwrap(
      nodes.first { $0["key"] as? String == "digest" }?["runs"] as? [[String: Any]])
    XCTAssertEqual(
      runs.map { ($0["result"] as? [String: Any])?["text"] as? String }, ["2 回目", "1 回目"])
  }

  /// 入力が 2 つの「届いたら」の処理が試走の中で 2 回確定しても、回ごとの結果はその回が足した行だけ（同じ時刻でも混ざらない）。
  func testEachRunOfANodeCarriesOnlyTheRowsItAdded() throws {
    let id = try define([
      fetch("gh"), fetch("backlog"), definitionNode("p", .arrival, from: ["gh", "backlog"]),
      definitionNode("d", from: ["p"], deliver: .report),
    ])
    let trial = try trials.start(.saved(id), .init(from: ["gh", "backlog"], to: ["p"]))
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
  var run: AutomationNodeRun? {
    if case .ran(let run, _, _) = self { run } else { nil }
  }

  var content: AutomationTrial.Content? {
    if case .ran(_, let content, _) = self { content } else { nil }
  }

  /// 止めた副作用・仕事に渡るはずだった行の id（下流へ渡す形。テスト）。止めた結果でなければ nil。
  var heldIds: [String]? {
    if case .held(let rows, _) = self { rows.compactMap(AutomationPrompts.id(of:)) } else { nil }
  }
}
