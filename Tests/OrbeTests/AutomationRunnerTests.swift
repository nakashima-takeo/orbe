import OrbeSessionLog
import XCTest

@testable import Orbe

/// 走らせ役——部品ごとの予定、溜まりから取って部品の 1 回に渡すこと、「届いたら」の部品の起こし方、1 つの契機での取り切り、
/// 書き換え。番人の時計と手段の実行だけを差し替え、ストアと DB と部品の 1 回は本物で回す。
///
/// 壊れると何が起きるか: 取得が溜めた項目が判定に届かない・判定の失敗で消える・同じ項目が二度判定に渡る。「届いたら」の部品が
/// 溜まりを抱えたまま誰にも起こされず、次の上流の回（毎日の取得なら 1 日）まで止まる。失敗した行で agent が即座に回り続ける。
/// 1 日に溜まる量が 1 回の上限を超えると、溜まりが日ごとに伸び続ける。新着の流れの取得が目印を失い、同じ項目を取り直すか取り
/// 逃す。書き換えた前の定義の結果が新しい定義の回として確定する、名前を変えただけで走っている回が殺される。
final class AutomationRunnerTests: OrbeTestCase {
  let start = Date(timeIntervalSince1970: 1_800_000_000)
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  private var armed: (date: Date, fire: () -> Void)?
  var jobs: FakeJobs!
  var store: AutomationStore!
  var runner: AutomationRunner!

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
      workspaces: { AutomationWorkspaces(listed: [], home: nil) }, recorded: { _, _ in },
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
  func part(
    _ key: String, _ trigger: AutomationPart.Trigger, from inputs: [String] = [],
    script: String? = nil, coverage: AutomationCoverage? = nil,
    deliver: AutomationPart.Destination = .nextPart
  ) -> AutomationPart {
    DesignSceneFixtures.commandPart(
      key, key, trigger, from: inputs, script: script ?? key, coverage: coverage, deliver: deliver)
  }

  /// 新着の流れを `seconds` ごとに取る取得の部品。
  func fetch(_ key: String, every seconds: TimeInterval, script: String? = nil) -> AutomationPart {
    part(key, .scheduled(.every(seconds)), script: script, coverage: .newArrivals)
  }

  func define(_ parts: [AutomationPart], name: String = "自動化") throws -> Int {
    try runner.set(nil, AutomationDefinition(name: name, notify: nil, parts: parts)).id
  }

  func inbox(_ key: String, of id: Int) -> Int? {
    store.automation(id)?.parts[key]?.inbox
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

  // MARK: - 溜まりと判定

  /// 取得の部品が回るたびに判定の溜まりが増え、判定の予定の時刻に溜まった分がまとめて渡って、溜まりが空になる。
  func testFetchesFillTheJudgesInboxAndTheJudgeTakesItAllAtItsTime() throws {
    let id = try define([
      fetch("gh", every: 1800), fetch("slack", every: 3600),
      part("judge", .scheduled(.every(86400)), from: ["gh", "slack"], deliver: .taskCandidates),
    ])

    advance(by: 1800)
    finish("gh", fetched(["a"]))
    XCTAssertEqual(inbox("judge", of: id), 1)
    advance(by: 1800)
    finish("gh", fetched(["a", "b"]))
    finish("slack", fetched(["s"]))
    XCTAssertEqual(inbox("judge", of: id), 3)
    XCTAssertEqual(calls("judge"), [], "判定は予定の時刻まで起きない")

    advance(by: 86400 - 3600)
    XCTAssertEqual(ids("judge"), ["gh:a", "gh:b", "slack:s"])
    finish("judge", printed(#"{"propose":"gh:a","title":"a に対応する"}"#))

    XCTAssertEqual(inbox("judge", of: id), 0)
    XCTAssertEqual(store.proposals.map(\.title), ["a に対応する"])
  }

  /// 判定が失敗しても溜まりは残り、取得は溜め続け、次の判定の回で同じ項目が渡る。
  func testAFailedJudgeKeepsItsInboxForTheNextJudge() throws {
    let id = try define([
      fetch("gh", every: 1800),
      part("judge", .scheduled(.every(3600)), from: ["gh"], deliver: .taskCandidates),
    ])
    advance(by: 1800)
    finish("gh", fetched(["a"]))

    advance(by: 1800)
    finish("judge", printed("", exit: 1))
    finish("gh", fetched(["a", "b"]))
    XCTAssertEqual(inbox("judge", of: id), 2, "失敗した回の行も残る")

    advance(by: 3600)
    XCTAssertEqual(ids("judge"), ["gh:a", "gh:b"])
  }

  /// 「届いたら」の部品が失敗しても、同じ行ですぐには回し直さず、上流の次の回の後に（新しい行が無くても）やり直す。
  func testAFailedArrivalPartRetriesAfterTheUpstreamsNextRunNotAtOnce() throws {
    _ = try define([
      fetch("gh", every: 1800),
      part("digest", .arrival, from: ["gh"], deliver: .report),
    ])
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    finish("digest", printed("", exit: 1))
    XCTAssertEqual(calls("digest").count, 1, "失敗した行ですぐ回し直さない")

    advance(by: 1800)
    finish("gh", fetched(["a"]))

    XCTAssertEqual(calls("digest").count, 2)
    XCTAssertEqual(ids("digest"), ["gh:a"])
  }

  /// 「届いたら」の部品が走っている間に届いた行は、その回が終わったら続けて起こして渡す。
  func testRowsArrivingWhileAnArrivalPartRunsAreTakenRightAfterIt() throws {
    let id = try define([
      fetch("gh", every: 1800),
      part("digest", .arrival, from: ["gh"], deliver: .report),
    ])
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    advance(by: 1800)
    finish("gh", fetched(["a", "b"]))
    XCTAssertEqual(calls("digest").count, 1, "走っている間は重ねない")

    finish("digest", printed("要約"))

    XCTAssertEqual(calls("digest").count, 2)
    XCTAssertEqual(ids("digest"), ["gh:b"])
    finish("digest", printed("要約"))
    XCTAssertEqual(inbox("digest", of: id), 0)
  }

  /// 届いたまま残っている行は、起動で載せたときに「届いたら」の部品を起こす。止めた自動化は起動では起こさず、再開で起こす。
  func testLeftoverRowsWakeArrivalPartsAtLaunchAndOnResumeButNotWhilePaused() throws {
    func seed(_ digest: String, paused: Bool) throws -> Int {
      let id = try store.create(
        AutomationDefinition(
          name: digest, notify: nil,
          parts: [
            fetch("gh", every: 86400),
            part("digest", .arrival, from: ["gh"], script: digest, deliver: .report),
          ]), now: now
      ).id
      _ = try store.record(
        AutomationPassEnd(
          automationId: id, part: "gh", trigger: .schedule, startedAt: now, endedAt: now,
          take: nil,
          outcome: DesignSceneFixtures.fetched(
            "gh", [AutomationItem(id: "a", link: "https://example.com/a", body: "a", time: now)])))
      if paused { _ = try store.setPaused(id, true) }
      return id
    }
    _ = try seed("active-digest", paused: false)
    let paused = try seed("paused-digest", paused: true)

    launch()

    XCTAssertEqual(ids("active-digest"), ["gh:a"], "起動で起こす")
    XCTAssertEqual(calls("paused-digest"), [], "止めた自動化は起動で起こさない")
    _ = try runner.pause(paused, false)
    XCTAssertEqual(ids("paused-digest"), ["gh:a"], "再開で起こす")
  }

  /// 1 回の上限を超えて溜まった行は、1 つの契機の中で続けて回して取り切る。
  func testOneTriggerTakesTheWholeInboxBeyondTheBatchLimit() throws {
    let id = try define([
      fetch("gh", every: 1800),
      DesignSceneFixtures.agentPart(
        "judge", "判定", .scheduled(.every(86400)), from: ["gh"], instruction: "判定する",
        deliver: .taskCandidates),
    ])
    let count = AutomationInbox.batchCount + 1
    advance(by: 1800)
    finish("gh", fetched((0..<count).map { "i\($0)" }))
    XCTAssertEqual(inbox("judge", of: id), count)

    advance(by: 86400 - 1800)
    let judged = BackgroundRunResult(
      commandLine: "claude -p", startedAt: now, endedAt: now, ending: .exited(0),
      output: .agent(
        reply: BackgroundAgentReply(text: #"{"nothing":"該当なし"}"#, isError: false),
        stderr: .init()))
    jobs.finish(try XCTUnwrap(agentCalls.first), judged)
    guard agentCalls.count == 2 else { return XCTFail("残りを同じ契機で続けて回す: \(agentCalls)") }
    jobs.finish(agentCalls[1], judged)

    XCTAssertEqual(inbox("judge", of: id), 0)
    XCTAssertEqual(
      store.automation(id)?.state("judge").runs.map(\.taken), [1, AutomationInbox.batchCount])
  }

  var agentCalls: [Int] {
    jobs.calls.indices.filter {
      if case .agent = jobs.calls[$0].job.work { return true }
      return false
    }
  }

  /// 回が走っている間に、取った行と同じ id の新しい行が届いて置き換わっても、その回の確定は新しい行を消さず、次の回に渡す。
  func testARowReplacedWhileAPartRunsSurvivesThatPartsCommit() throws {
    let id = try define([
      part("gh", .scheduled(.every(1800)), coverage: .everything),
      part("digest", .scheduled(.every(3600)), from: ["gh"], deliver: .report),
    ])
    advance(by: 1800)
    finish("gh", printed(item("a", body: "古い本文")))

    advance(by: 1800)
    XCTAssertEqual(bodies("digest"), ["古い本文"])
    finish("gh", printed(item("a", body: "新しい本文")))
    finish("digest", printed("要約"))
    XCTAssertEqual(inbox("digest", of: id), 1, "置き換わった新しい行は残る")

    advance(by: 3600)
    XCTAssertEqual(calls("digest").count, 2)
    XCTAssertEqual(bodies("digest"), ["新しい本文"])
  }

  // MARK: - 目印

  /// 新着の流れの取得は、前回成功した回の始まりを目印（`ORBE_SINCE`）に受ける。失敗した回では目印は進まない。
  func testANewArrivalsFetchGetsTheStartOfItsLastSuccessfulRun() throws {
    _ = try define([
      fetch("gh", every: 1800),
      part("digest", .arrival, from: ["gh"], deliver: .report),
    ])
    func since() -> String? { calls("gh").last.flatMap { input($0)?.environment["ORBE_SINCE"] } }

    advance(by: 1800)
    XCTAssertNil(since(), "一度も成功していなければ目印は無い")
    finish("gh", fetched(["a"]))
    advance(by: 1800)
    XCTAssertEqual(since(), SessionEvent.iso8601(start.addingTimeInterval(1800)))
    finish("gh", printed("", exit: 1))
    advance(by: 1800)

    XCTAssertEqual(since(), SessionEvent.iso8601(start.addingTimeInterval(1800)))
  }

  // MARK: - 書き換え

  /// 書き換えは、何をするかが変わった部品の走っている回だけを止めて結果を捨てる。名前だけの書き換えでは走っている回が最後
  /// まで走って確定する。どちらでも溜まりは残る。
  func testRewritingStopsOnlyAPartWhoseWorkChangedAndKeepsTheInbox() throws {
    func definition(_ name: String, gh script: String) -> AutomationDefinition {
      AutomationDefinition(
        name: name, notify: nil,
        parts: [
          fetch("gh", every: 1800, script: script),
          part("judge", .scheduled(.every(86400)), from: ["gh"], deliver: .taskCandidates),
        ])
    }
    let id = try runner.set(nil, definition("受信", gh: "gh")).id
    advance(by: 1800)
    finish("gh", fetched(["a"]))

    advance(by: 1800)
    _ = try runner.set(id, definition("受信（改名）", gh: "gh"))
    XCTAssertEqual(jobs.stopped, [], "名前だけなら走っている回を止めない")
    finish("gh", fetched(["a", "b"]))
    XCTAssertEqual(store.automation(id)?.state("gh").runs.count, 2)

    advance(by: 1800)
    let running = try XCTUnwrap(calls("gh").last)
    _ = try runner.set(id, definition("受信（改名）", gh: "gh --all"))
    XCTAssertEqual(jobs.stopped, [running])
    jobs.finish(running, fetched(["a", "b", "c"]))

    XCTAssertEqual(store.automation(id)?.state("gh").runs.count, 2, "止めた回の結果は確定しない")
    XCTAssertEqual(inbox("judge", of: id), 2)
  }
}
