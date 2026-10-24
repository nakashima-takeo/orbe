import XCTest

@testable import Orbe

/// 試走の止める部品と与える行——副作用と仕事は写しの上でも動かさず、与えた行はある部品の出力として写しに書く。
///
/// 壊れると何が起きるか: 試走で副作用や仕事が本当に走る。止めた部品に何が渡るはずだったかが分からない。与えた行が流れない、
/// または本番の取得が走る。
extension AutomationTrialTests {
  /// 副作用と仕事（ツールを持つ agent）は写しの上でも動かさず、流しの終わりに渡るはずだった行を 1 つにまとめて返す。回の記録は
  /// 持たない。
  func testSideEffectsAndWorkAreHeldWithTheRowsTheyWouldHaveGot() throws {
    let id = try define([
      fetch("gh"), definitionNode("send", .arrival, from: ["gh"], deliver: .sideEffect),
      DesignSceneFixtures.agentNode(
        "job", "job", .arrival, from: ["gh"], tools: ["Bash(git status:*)"], instruction: "do",
        deliver: .report),
    ])
    let trial = try trials.start(id, .init())
    waitCalls("gh", 1)
    finish("gh", fetched(["a"]))
    ended(trial)

    XCTAssertEqual(calls("send"), [])
    XCTAssertEqual(
      jobs.calls.filter {
        if case .agent = $0.job.work { return true }
        return false
      }.count, 0)
    for key in ["send", "job"] {
      XCTAssertEqual(trial.state(key: key), .held, key)
      XCTAssertEqual(trial.passes(key: key).count, 1, key)
      guard case .held(let held) = trial.passes(key: key).first else {
        return XCTFail("\(key) に止めた行が無い")
      }
      XCTAssertEqual(
        held.compactMap(AutomationPrompts.id(of:)), [downstream("gh", "a", of: id)], key)
    }
  }

  /// 行を見る agent は試走でも本番と同じく行を Orbe の MCP で読み、その回の札は写しの DB のまだ受け取っていない行と、入口に
  /// 与えた行を返す。
  func testAnAgentReadingRowsReadsTheCopysRowsAndTheGivenRows() throws {
    let id = try define([
      fetch("gh"),
      DesignSceneFixtures.agentNode("p", "処理", .manual, from: ["gh"], instruction: "残す"),
      definitionNode("digest", from: ["p"], deliver: .report),
    ])
    try runner.flow(id, to: .node(store.nodeId(id, "gh")))
    finish("gh", fetched(["a"]))
    XCTAssertEqual(store.automation(id)?.state(key: "p").pending.count, 1)

    let trial = try trials.start(id, .init(from: ["p"], rows: [#"{"id":"x"}"#]))
    let agents = {
      self.jobs.calls.indices.filter {
        if case .agent = self.jobs.calls[$0].job.work { return true }
        return false
      }
    }
    settle(until: { agents().count == 1 })
    guard let index = agents().first, case .agent(let call) = jobs.calls[index].job.work else {
      return XCTFail("p の agent が呼ばれていない")
    }
    let session = try XCTUnwrap(call.orbe.flatMap { runner.runSessions.session($0.token) })
    let page = session.call("read_run_rows", [:]).texts.last ?? ""
    XCTAssertEqual(
      page.split(separator: "\n").compactMap { AutomationPrompts.id(of: String($0)) },
      [downstream("gh", "a", of: id), downstream("gh", "x", of: id)])
    _ = session.call("report_nothing", ["why": "残る項目なし"])
    XCTAssertFalse(call.prompt.contains(downstream("gh", "a", of: id)), "行の中身は依頼文に載せない")
    jobs.finish(
      index,
      BackgroundRunResult(
        commandLine: "claude -p", startedAt: now, endedAt: now, ending: .exited(0),
        output: .agent(reply: BackgroundAgentReply(text: "done", isError: false), stderr: .init())))
    ended(trial)
  }

  /// 取得の入口に与えた行は、手段を起こさず、本番が既に出した出来事と同じ id でも接頭の付いた id で下流へ流れる。その取得は
  /// 回の記録を持たず、与えた行を結果にする。判定へ与えると断る。
  func testRowsGivenToAFetchFlowDownWithoutItsMethodAndAJudgeRefusesThem() throws {
    let id = try define([
      DesignSceneFixtures.commandNode(
        "gh", "gh", .manual, script: "gh", coverage: .newArrivals),
      definitionNode("judge", from: ["gh"], deliver: .taskCandidates),
    ])
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("judge", "")

    let trial = try trials.start(id, .init(rows: [item("a")]))
    waitCalls("judge", 2)
    XCTAssertEqual(ids("judge"), [downstream("gh", "a", of: id)])
    XCTAssertEqual(calls("gh").count, 1)
    finish("judge", "")
    ended(trial)
    XCTAssertEqual(trial.state(key: "gh"), .given)
    XCTAssertEqual(trial.passes(key: "gh").count, 1)
    guard case .given(let given) = trial.passes(key: "gh").first else {
      return XCTFail("gh に与えた行が無い")
    }
    XCTAssertEqual(given.compactMap(AutomationPrompts.id(of:)), [downstream("gh", "a", of: id)])

    XCTAssertThrowsError(
      try trials.start(id, .init(from: ["judge"], to: ["judge"], rows: [#"{"id":"x"}"#]))
    ) {
      guard case .invalid = $0 as? AutomationError else { return XCTFail("\($0)") }
    }
    XCTAssertThrowsError(try trials.start(id, .init(rows: [#"{"id":"x"}"#]))) {
      XCTAssertEqual($0 as? AutomationError, .invalid("rows: item 1: missing link"))
    }
  }

  /// 入力のある入口に与えた行は、ただ 1 つの上流（の写し）の出力として足され、上流の行として（接頭付きの id で）取られる。
  /// 「届いたら」の入口も今すぐ動き、その回は今すぐの回として記録される。上流が複数の入口に与えると断り、上限を超える行も断る。
  func testRowsGivenToANodeWithInputsArriveAsTheRowsOfItsUpstream() throws {
    let id = try define([
      fetch("gh"), definitionNode("p", .arrival, from: ["gh"]),
      definitionNode("digest", from: ["p"], deliver: .report),
    ])
    let trial = try trials.start(
      id, .init(from: ["p"], rows: [#"{"id":"x","note":"手作り"}"#]))
    waitCalls("p", 1)
    let x = downstream("gh", "x", of: id)
    XCTAssertEqual(ids("p"), [x])
    XCTAssertEqual(calls("gh"), [])
    finish("p", #"{"id":"\#(x)"}"#)
    waitCalls("digest", 1)
    finish("digest", "x")
    ended(trial)
    XCTAssertEqual(store.automation(id)?.state(key: "p").pending.count, 0)
    XCTAssertEqual(trial.passes(key: "p").first?.run?.trigger, .now)

    let merged = try define([
      fetch("gh"), fetch("slack"), definitionNode("p", from: ["gh", "slack"]),
      definitionNode("digest", from: ["p"], deliver: .report),
    ])
    XCTAssertThrowsError(try trials.start(merged, .init(from: ["p"], rows: [#"{"id":"x"}"#]))) {
      guard case .invalid(let message) = $0 as? AutomationError else { return XCTFail("\($0)") }
      XCTAssertTrue(message.hasPrefix(#"rows: "p" has 2 inputs"#), message)
    }

    let large = String(repeating: "x", count: AutomationOutputs.rowKiB << 10)
    XCTAssertThrowsError(
      try trials.start(id, .init(from: ["p"], rows: [#"{"id":"y","note":"\#(large)"}"#]))
    ) {
      XCTAssertEqual($0 as? AutomationError, .invalid("rows: item 1: larger than 64 KiB"))
    }
  }
}
