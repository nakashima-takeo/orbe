import OrbeSessionLog
import XCTest

@testable import Orbe

/// 走らせ役——部品ごとの予定、上流から読んで部品の 1 回に渡すこと、「届いたら」の部品の起こし方、読めば取る行を 1 回で
/// 取り切ること、書き換え。番人の時計と手段の実行だけを差し替え、ストアと DB と部品の 1 回は本物で回す。
///
/// 壊れると何が起きるか: 取得が出した項目が判定に届かない・判定の失敗で消える・同じ項目が二度判定に渡る。「届いたら」の部品が
/// 読めば取る行を抱えたまま誰にも起こされず、次の上流の回（毎日の取得なら 1 日）まで止まる。失敗した行で agent が即座に回り
/// 続ける。読めば取る行を一部しか取らず、読み残しが日ごとに伸び続ける。新着の流れの取得が目印を失い、同じ項目を取り直すか
/// 取り逃す。書き換えた前の定義の結果が新しい定義の回として確定する、名前を変えただけで走っている回が殺される。
final class AutomationRunnerTests: OrbeTestCase {
  let start = Date(timeIntervalSince1970: 1_800_000_000)
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  private var armed: (date: Date, fire: () -> Void)?
  var jobs: FakeJobs!
  var store: AutomationStore!
  var runner: AutomationRunner!
  /// 走らせ役が回を記録したと知らせた部品の鍵（知らせた順）。
  var recorded: [String] = []

  override func setUp() {
    jobs = FakeJobs()
    launch()
  }

  /// ストアを開いて走らせ役を起動する。開き直すときは前のストアを手放してから（DB は排他）。
  func launch() {
    runner = nil
    store = nil
    store = AutomationStore()
    let scheduler = BackgroundScheduler { _, _ in BackgroundRunHandle {} }
    scheduler.now = { [unowned self] in now }
    scheduler.calendar = { Calendar(identifier: .gregorian) }
    scheduler.arm = { [unowned self] date, fire in
      armed = (date, fire)
      return { [unowned self] in armed = nil }
    }
    runner = AutomationRunner(
      store: store, scheduler: scheduler, run: jobs.run,
      workspaces: { AutomationWorkspaces(listed: [], home: nil) },
      recorded: { [unowned self] record in
        recorded.append(
          store.automation(record.end.automationId)?.graph.node(record.end.nodeId)?.key ?? "?")
      },
      defined: { _ in }, deleted: { _ in })
    runner.now = { [unowned self] in now }
    runner.calendar = { Calendar(identifier: .gregorian) }
    runner.start()
  }

  func advance(by seconds: TimeInterval) {
    now = now.addingTimeInterval(seconds)
    while let due = armed, due.date <= now {
      armed = nil
      due.fire()
    }
  }

  // MARK: - 部品

  /// コマンドの部品。スクリプトは既定で部品の鍵（呼び出しを部品ごとに見分けるため）。
  func definitionNode(
    _ key: String, _ trigger: AutomationNode.Trigger, from inputs: [String] = [],
    script: String? = nil, coverage: AutomationCoverage? = nil,
    deliver: AutomationActionDef.Destination = .nextNode
  ) -> AutomationDefinition.Node {
    DesignSceneFixtures.commandNode(
      key, key, trigger, from: inputs, script: script ?? key, coverage: coverage, deliver: deliver)
  }

  /// 新着の流れを `seconds` ごとに取る取得の部品。
  func fetch(_ key: String, every seconds: TimeInterval, script: String? = nil)
    -> AutomationDefinition.Node
  {
    definitionNode(key, .scheduled(.every(seconds)), script: script, coverage: .newArrivals)
  }

  func define(_ definitionNodes: [AutomationDefinition.Node], name: String = "自動化") throws -> Int {
    try runner.set(nil, AutomationDefinition(name: name, notify: nil, nodes: definitionNodes)).id
  }

  /// 今の版で書き換える。同じ鍵の部品は今の部品の id を添える（同じ部品のまま）。
  @discardableResult func rewrite(_ id: Int, _ definition: AutomationDefinition) throws
    -> Automation
  {
    let current = try XCTUnwrap(store.automation(id))
    var definition = definition
    for index in definition.nodes.indices {
      definition.nodes[index].id = current.graph.node(key: definition.nodes[index].key)?.id
    }
    return try runner.set(id, version: current.version, definition)
  }

  func pending(_ key: String, of id: Int) -> Int? {
    store.automation(id)?.state(key: key).pending.count
  }

  /// 下流へ渡す id（`<部品 ID>:<書かれた id>`）。
  func downstream(_ key: String, _ written: String, of id: Int) -> String {
    "\(store.nodeId(id, key)):\(written)"
  }

  // MARK: - 手段の呼び出し

  /// スクリプトが `script` の呼び出しの番号（呼ばれた順）。
  func calls(_ script: String) -> [Int] {
    jobs.calls.indices.filter {
      if case .command(let command, _) = jobs.calls[$0].job.work { return command.script == script }
      return false
    }
  }

  func input(_ index: Int) -> BackgroundInput? {
    guard case .command(_, let input) = jobs.calls[index].job.work else { return nil }
    return input
  }

  /// 呼び出しに標準入力で渡した行（JSON のオブジェクト）。
  func rows(_ index: Int) -> [[String: Any]] {
    let text = String(bytes: input(index)?.stdin ?? Data(), encoding: .utf8) ?? ""
    return text.split(separator: "\n").compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
  }

  /// 最後に呼んだ `script` に渡した行の id。
  func ids(_ script: String) -> [String] {
    guard let last = calls(script).last else { return [] }
    return rows(last).compactMap { $0["id"] as? String }
  }

  /// 最後に呼んだ `script` に渡した行の本文。
  func bodies(_ script: String) -> [String] {
    guard let last = calls(script).last else { return [] }
    return rows(last).compactMap { $0["body"] as? String }
  }

  /// 最後に呼んだ `script` を終える。
  func finish(_ script: String, _ result: BackgroundRunResult) {
    guard let last = calls(script).last else { return XCTFail("\(script) は呼ばれていない") }
    jobs.finish(last, result)
  }

  func printed(_ stdout: String, exit: Int32 = 0) -> BackgroundRunResult {
    BackgroundRunResult(
      commandLine: "run", startedAt: now, endedAt: now, ending: .exited(exit),
      output: .command(stdout: .init(data: Data(stdout.utf8)), stderr: .init()))
  }

  func item(_ id: String, body: String? = nil) -> String {
    let body = body ?? "\(id) の本文"
    return #"{"id":"\#(id)","link":"https://example.com/\#(id)","body":"\#(body)","#
      + #""time":"2026-10-10T09:00:00Z"}"#
  }

  func fetched(_ ids: [String]) -> BackgroundRunResult {
    printed(ids.map { item($0) }.joined(separator: "\n"))
  }

  // MARK: - 読めば取る行と判定

  /// 取得の部品が回るたびに判定が読めば取る行が増え、判定の予定の時刻にその分がまとめて渡って、0 件になる。
  func testFetchesAddToTheJudgesPendingRowsAndTheJudgeTakesThemAllAtItsTime() throws {
    let id = try define([
      fetch("gh", every: 1800), fetch("slack", every: 3600),
      definitionNode(
        "judge", .scheduled(.every(86400)), from: ["gh", "slack"], deliver: .taskCandidates),
    ])

    advance(by: 1800)
    finish("gh", fetched(["a"]))
    XCTAssertEqual(pending("judge", of: id), 1)
    advance(by: 1800)
    finish("gh", fetched(["a", "b"]))
    finish("slack", fetched(["s"]))
    XCTAssertEqual(pending("judge", of: id), 3)
    XCTAssertEqual(calls("judge"), [], "判定は予定の時刻まで起きない")

    advance(by: 86400 - 3600)
    XCTAssertEqual(
      ids("judge"),
      [
        downstream("gh", "a", of: id), downstream("gh", "b", of: id),
        downstream("slack", "s", of: id),
      ])
    finish(
      "judge", printed(#"{"propose":"\#(downstream("gh", "a", of: id))","title":"a に対応する"}"#))

    XCTAssertEqual(pending("judge", of: id), 0)
    XCTAssertEqual(store.proposals.map(\.title), ["a に対応する"])
  }

  /// 判定が失敗しても読めば取る行は残り、取得は足し続け、次の判定の回で同じ項目が渡る。
  func testAFailedJudgeKeepsItsPendingRowsForTheNextJudge() throws {
    let id = try define([
      fetch("gh", every: 1800),
      definitionNode("judge", .scheduled(.every(3600)), from: ["gh"], deliver: .taskCandidates),
    ])
    advance(by: 1800)
    finish("gh", fetched(["a"]))

    advance(by: 1800)
    finish("judge", printed("", exit: 1))
    finish("gh", fetched(["a", "b"]))
    XCTAssertEqual(pending("judge", of: id), 2, "失敗した回の行も残る")

    advance(by: 3600)
    XCTAssertEqual(ids("judge"), [downstream("gh", "a", of: id), downstream("gh", "b", of: id)])
  }

  /// 「届いたら」の部品が失敗しても、同じ行ですぐには回し直さず、上流の次の回の後に（新しい行が無くても）やり直す。
  func testAFailedArrivalNodeRetriesAfterTheUpstreamsNextRunNotAtOnce() throws {
    let id = try define([
      fetch("gh", every: 1800),
      definitionNode("digest", .arrival, from: ["gh"], deliver: .report),
    ])
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    finish("digest", printed("", exit: 1))
    XCTAssertEqual(calls("digest").count, 1, "失敗した行ですぐ回し直さない")

    advance(by: 1800)
    finish("gh", fetched(["a"]))

    XCTAssertEqual(calls("digest").count, 2)
    XCTAssertEqual(ids("digest"), [downstream("gh", "a", of: id)])
  }

  /// 「届いたら」の部品が走っている間に届いた行は、その回が終わったら続けて起こして渡す。
  func testRowsArrivingWhileAnArrivalNodeRunsAreTakenRightAfterIt() throws {
    let id = try define([
      fetch("gh", every: 1800),
      definitionNode("digest", .arrival, from: ["gh"], deliver: .report),
    ])
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    advance(by: 1800)
    finish("gh", fetched(["a", "b"]))
    XCTAssertEqual(calls("digest").count, 1, "走っている間は重ねない")

    finish("digest", printed("要約"))

    XCTAssertEqual(calls("digest").count, 2)
    XCTAssertEqual(ids("digest"), [downstream("gh", "b", of: id)])
    finish("digest", printed("要約"))
    XCTAssertEqual(pending("digest", of: id), 0)
  }

  /// 届いたまま残っている行は、起動で載せたときに「届いたら」の部品を起こす。止めた自動化は起動では起こさず、再開で起こす。
  func testLeftoverRowsWakeArrivalNodesAtLaunchAndOnResumeButNotWhilePaused() throws {
    func seed(_ digest: String, paused: Bool) throws -> Int {
      let id = try store.create(
        AutomationDefinition(
          name: digest, notify: nil,
          nodes: [
            fetch("gh", every: 86400),
            definitionNode("digest", .arrival, from: ["gh"], script: digest, deliver: .report),
          ]), now: now
      ).id
      try store.record(
        id, nodeKey: "gh", at: now,
        outcome: DesignSceneFixtures.fetched([
          AutomationItem(id: "a", link: "https://example.com/a", body: "a", time: now)
        ]))
      if paused { _ = try store.setPaused(id, true, now: now) }
      return id
    }
    let active = try seed("active-digest", paused: false)
    let paused = try seed("paused-digest", paused: true)

    launch()

    XCTAssertEqual(ids("active-digest"), [downstream("gh", "a", of: active)], "起動で起こす")
    XCTAssertEqual(calls("paused-digest"), [], "止めた自動化は起動で起こさない")
    _ = try runner.pause(paused, false)
    XCTAssertEqual(ids("paused-digest"), [downstream("gh", "a", of: paused)], "再開で起こす")
  }

  /// 行を見る agent は、まだ受け取っていない行を件数と大きさによらず 1 回で全部取る。
  func testOneRunTakesEveryPendingRow() throws {
    let id = try define([
      fetch("gh", every: 1800),
      DesignSceneFixtures.agentNode(
        "judge", "判定", .scheduled(.every(86400)), from: ["gh"], instruction: "判定する",
        deliver: .taskCandidates),
    ])
    let body = String(repeating: "本文", count: 1 << 10)
    let items = (0..<150).map { item("i\($0)", body: body) }
    advance(by: 1800)
    finish("gh", printed(items.joined(separator: "\n")))
    XCTAssertEqual(pending("judge", of: id), items.count)

    advance(by: 86400 - 1800)
    let index = try XCTUnwrap(agentCalls.first)
    guard case .agent(let call) = jobs.calls[index].job.work,
      let session = call.orbe.flatMap({ runner.runSessions.session($0.token) })
    else { return XCTFail("判定の回の口が無い") }
    var offset: Int? = 0
    while let next = offset {
      let head = session.call("read_run_rows", ["offset": next, "limit": 100]).texts.first ?? ""
      offset =
        (try? JSONSerialization.jsonObject(with: Data(head.utf8)) as? [String: Any])?["next"]
        as? Int
    }
    XCTAssertFalse(session.call("report_nothing", ["why": "該当なし"]).isError)
    jobs.finish(
      index,
      BackgroundRunResult(
        commandLine: "claude -p", startedAt: now, endedAt: now, ending: .exited(0),
        output: .agent(reply: BackgroundAgentReply(text: "done", isError: false), stderr: .init())))

    XCTAssertEqual(agentCalls.count, 1)
    XCTAssertEqual(pending("judge", of: id), 0)
    XCTAssertEqual(
      store.automation(id)?.state(store.nodeId(id, "judge")).runs.map(\.run?.taken), [items.count])
  }

  var agentCalls: [Int] {
    jobs.calls.indices.filter {
      if case .agent = jobs.calls[$0].job.work { return true }
      return false
    }
  }

  // MARK: - 目印

  /// 新着の流れの取得は、前回成功した回の始まりを目印（`ORBE_SINCE`）に受ける。失敗した回では目印は進まない。
  func testANewArrivalsFetchGetsTheStartOfItsLastSuccessfulRun() throws {
    _ = try define([
      fetch("gh", every: 1800),
      definitionNode("digest", .arrival, from: ["gh"], deliver: .report),
    ])
    func since() -> String? { calls("gh").last.flatMap { input($0)?.environment["ORBE_SINCE"] } }

    advance(by: 1800)
    XCTAssertNil(since(), "一度も成功していなければ目印は無い")
    advance(by: 600)
    finish("gh", fetched(["a"]))
    advance(by: 1800)
    XCTAssertEqual(since(), SessionEvent.iso8601(start.addingTimeInterval(1800)))
    finish("gh", printed("", exit: 1))
    advance(by: 1800)

    XCTAssertEqual(since(), SessionEvent.iso8601(start.addingTimeInterval(1800)))
  }
}
