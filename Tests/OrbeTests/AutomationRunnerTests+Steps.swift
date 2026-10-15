import OrbeSessionLog
import XCTest

@testable import Orbe

/// 段の列と前回成功の目印。段は取得元の項目を JSON の行で受けて順に回り、回の記録に段ごとの件数が残る。項目は取得元の
/// `id` でたどり、最後の段に届く行が 1 つも無い回・中間の段で全行が形違いの回は失敗にする（最後の段の形違いは捨てるだけ）。
/// 新着の流れの取得元にだけ、前回成功した回の開始時刻を渡す。
///
/// 壊れると何が起きるか: 段の途中で id が落ちた回を成功と読み、項目が「見たもの」になって二度と判定に回らない。目印が
/// 失敗した回で進み、その間に届いた項目を取りこぼす。
extension AutomationRunnerTests {
  private func printed(_ text: String, exit: Int32 = 0) -> BackgroundRunResult {
    BackgroundRunResult(
      commandLine: "jq", startedAt: Date(), endedAt: Date(), ending: .exited(exit),
      output: .command(stdout: .init(data: Data(text.utf8)), stderr: .init()))
  }

  private func filtered() -> AutomationDefinition {
    var definition = AutomationStoreTests.definition()
    definition.steps.insert(
      AutomationStep(name: "絞り込み", method: .command(BackgroundCommand(script: "jq -c ."))), at: 0)
    return definition
  }

  func testStepsRunInOrderAndRecordTheirCounts() throws {
    let automation = try create(filtered())
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a", "b", "c"]))

    guard case .command(_, let input) = jobs.calls[1].job.work else {
      return XCTFail("絞り込みはコマンド")
    }
    let stdin = String(bytes: input.stdin ?? Data(), encoding: .utf8) ?? ""
    XCTAssertEqual(stdin.split(separator: "\n").count, 3, "項目を 1 行ずつ標準入力で渡す")
    let rewritten = #"{"id":"b","link":"https://evil.example/","body":"段が書いた本文"}"#
    jobs.finish(1, printed(rewritten + "\nnot json\n"))

    XCTAssertTrue(prompt(2).contains(#""id":"b""#))
    XCTAssertFalse(prompt(2).contains(#""id":"a""#), "絞り込んだ行だけを最後の段へ")
    jobs.finish(2, replied(#"{"propose":"b","title":"b に返信する"}"#))

    let run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertNil(run.failure)
    XCTAssertEqual(run.source?.count, 3)
    XCTAssertEqual(run.fresh, 3)
    XCTAssertEqual(run.steps.map(\.name), ["絞り込み", "判定"])
    XCTAssertEqual(run.steps.map(\.count), [1, 1])
    XCTAssertTrue(run.lastStepCountedBySink, "最後の段の数は出力先が数えた")
    XCTAssertEqual(run.steps[0].rejected.count, 1)
    XCTAssertEqual(AutomationStoreTests.candidates(run)?.proposed, 1)
    XCTAssertEqual(store.proposals.map(\.item.link), ["https://example.com/b"], "リンクは取得元の項目から")
    XCTAssertEqual(store.proposals.map(\.item.body), ["b の本文"], "本文は取得元の項目から")
  }

  /// 中間の agent の段は、ツールを持たずに指示文と項目の行を受け、渡す項目の id を保つよう頼まれる——id を落とすと回が
  /// 毎回失敗する。モデルを省略すると haiku で走る。
  func testAMiddleAgentStepIsAskedToKeepTheIdsOfTheItemsItPassesOn() throws {
    var definition = AutomationStoreTests.definition()
    definition.steps.insert(
      AutomationStep(
        name: "英語だけ",
        method: .agent(
          AutomationStepAgent(cli: "claude", model: nil, instruction: "英語の項目だけ残す"))),
      at: 0)
    let automation = try create(definition)
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a", "b"]))

    guard case .agent(let call) = jobs.calls[1].job.work else { return XCTFail("中間の段は agent") }
    XCTAssertEqual(call.tools, [])
    XCTAssertEqual(call.model, "haiku")
    XCTAssertTrue(call.prompt.contains("英語の項目だけ残す"))
    XCTAssertTrue(call.prompt.contains(#""id":"a""#) && call.prompt.contains(#""id":"b""#))
    XCTAssertTrue(call.prompt.contains(#"Keep the "id" of each item you pass on"#))
  }

  /// 最後の段は判断を担うので、モデルを省略すると sonnet で走る。
  func testTheLastAgentStepRunsOnSonnetWhenTheModelIsOmitted() throws {
    var definition = AutomationStoreTests.definition()
    definition.steps = [
      AutomationStep(
        name: "判定",
        method: .agent(AutomationStepAgent(cli: "claude", model: nil, instruction: "判定して")))
    ]
    let automation = try create(definition)
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a"]))

    guard case .agent(let call) = jobs.calls[1].job.work else { return XCTFail("最後の段は agent") }
    XCTAssertEqual(call.model, "sonnet")
  }

  /// 中間の段が何も残さなければ（空か、最後の行が `{"nothing": …}`）、最後の段を起こさずに成功として確定する。記録の最後の段は
  /// 0 行を出した段で、出力先は数えていない。
  func testAnEmptyMiddleStepCommitsWithoutTheLastStep() throws {
    let automation = try create(filtered())
    for (index, (id, output)) in [("a", ""), ("b", #"{"nothing": "残る項目なし"}"#)].enumerated() {
      try runner.runNow(automation.id)
      jobs.finish(index * 2, fetched([id]))
      jobs.finish(index * 2 + 1, printed(output))

      XCTAssertEqual(jobs.calls.count, index * 2 + 2, output)
      let run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
      XCTAssertNil(run.failure)
      XCTAssertEqual(run.steps.map(\.count), [0])
      XCTAssertEqual(run.steps.map(\.rejected.count), [0])
      XCTAssertFalse(run.lastStepCountedBySink)
      XCTAssertEqual(store.automation(automation.id)?.lastFetched.map(\.id), [id])
    }
  }

  func testAMiddleStepWithOnlyMalformedLinesFails() throws {
    let automation = try create(filtered())
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a"]))
    jobs.finish(1, printed("oops\n"))

    XCTAssertEqual(
      store.automation(automation.id)?.runs.first?.failure,
      #"every line of the output of step "絞り込み" was malformed"#)
    XCTAssertEqual(store.automation(automation.id)?.lastFetched, [], "見たことにしない")
  }

  /// 最後の段に渡す行が、どれも今回の新しい項目の id を持たなければ（落とした・別の id に変えた）失敗にする。
  func testLosingTheIdBeforeTheLastStepFails() throws {
    let automation = try create(filtered())
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a"]))
    jobs.finish(1, printed(#"{"title":"id の無い行"}"# + "\n" + #"{"id":"z","title":"知らない id"}"#))

    XCTAssertEqual(jobs.calls.count, 2, "最後の段を起こさない")
    XCTAssertEqual(
      store.automation(automation.id)?.runs.first?.failure,
      "no line passed to the last step has the id of a new item")
    XCTAssertEqual(store.automation(automation.id)?.lastFetched, [])
  }

  /// 最後の段の形違いの行は捨てるだけで、文章だけを返した回は候補なしで確定する。
  func testProseFromTheLastStepCommitsWithNoCandidates() throws {
    let automation = try create()
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a"]))
    jobs.finish(1, replied("タスクにすべきものはありません。"))

    XCTAssertNil(store.automation(automation.id)?.runs.first?.failure)
    XCTAssertEqual(store.automation(automation.id)?.lastFetched.map(\.id), ["a"], "見たことにする")
    XCTAssertEqual(store.proposals, [])
  }

  /// 新着の流れの取得元には前回成功した回の開始時刻が渡り、失敗した回では進まない。
  func testNewArrivalsGetTheStartOfTheLastSuccessfulRun() throws {
    var definition = AutomationStoreTests.definition(coverage: .newArrivals)
    definition.source?.method = AutomationStoreTests.agentSource()
    let automation = try create(definition)
    let runStart = now
    try runner.runNow(automation.id)
    XCTAssertEqual(prompt(0), AutomationPrompts.fetch(request: "自分宛の DM"), "初回は目印なし")
    now = runStart.addingTimeInterval(600)
    jobs.finish(0, replied(""))
    let stored = try XCTUnwrap(store.automation(automation.id))
    XCTAssertEqual(stored.runs.first?.endedAt, runStart.addingTimeInterval(600))
    let succeeded = try XCTUnwrap(stored.lastSucceededAt)
    XCTAssertEqual(succeeded, runStart, "回の終わりでなく始まり——回の途中に届いた分を次の回で取りこぼさない")

    try runner.runNow(automation.id)
    XCTAssertTrue(prompt(1).contains(SessionEvent.iso8601(succeeded)), prompt(1))
    jobs.finish(1, replied("overloaded", isError: true))
    XCTAssertEqual(store.automation(automation.id)?.lastSucceededAt, succeeded, "失敗した回では進まない")

    var command = AutomationStoreTests.definition(coverage: .newArrivals)
    command.name = "コマンド"
    let commanded = try create(command)
    try runner.runNow(commanded.id)
    jobs.finish(2, fetched([]))
    try runner.runNow(commanded.id)
    guard case .command(_, let input) = jobs.calls[3].job.work else {
      return XCTFail("取得元はコマンド")
    }
    XCTAssertEqual(
      input.environment["ORBE_SINCE"],
      SessionEvent.iso8601(try XCTUnwrap(store.automation(commanded.id)?.lastSucceededAt)))
  }

  /// 取得元か処理を書き換えた直後の全件見直しの回にも、目印は渡る——外すと、さばいて忘れた候補が取得に戻って二重に出る。
  func testReworkedNewArrivalsStillGetTheMark() throws {
    var definition = AutomationStoreTests.definition(coverage: .newArrivals)
    definition.source?.method = AutomationStoreTests.agentSource()
    let automation = try create(definition)
    try runner.runNow(automation.id)
    jobs.finish(0, replied(""))
    let succeeded = try XCTUnwrap(store.automation(automation.id)?.lastSucceededAt)

    definition.steps = [AutomationStoreTests.judgeStep("別の指示")]
    _ = try runner.set(automation.id, definition)
    try runner.runNow(automation.id)

    XCTAssertTrue(prompt(1).contains(SessionEvent.iso8601(succeeded)), prompt(1))
  }

  /// 今の集合の取得元には目印を渡さない——渡すと前回以降の分だけが取れ、取得から消えたものとして候補が一斉に下がる。
  func testCurrentSetGetsNoMark() throws {
    var definition = AutomationStoreTests.definition(coverage: .currentSet)
    definition.source?.method = AutomationStoreTests.agentSource()
    let automation = try create(definition)
    try runner.runNow(automation.id)
    jobs.finish(0, replied(""))
    XCTAssertNotNil(store.automation(automation.id)?.lastSucceededAt)

    try runner.runNow(automation.id)

    XCTAssertEqual(prompt(1), AutomationPrompts.fetch(request: "自分宛の DM"))
  }
}
