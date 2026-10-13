import XCTest

@testable import Orbe

/// 出力先の agent。届いた行は「起こすか」を決めるだけで、依頼文は Orbe の枠と定義の依頼文だけ。名指しの規則をそのまま裏の
/// agent に渡し、最終応答を報告と同じく回の結果に残す。`{"nothing": …}` の 1 行はすることが無いという申告。`{"error": …}` の
/// 1 行・落ちた・揃わなかった回は失敗で、項目は次の回にもう一度流れる。
///
/// 壊れると何が起きるか: 取得した外の文面が、書き込みのツールを持つ agent の依頼文に入り、仕込まれた指示で投稿される。新着の
/// 無い回にも agent が起きて投稿が重なる。agent ができなかった回が成功と読まれ、知らせが出ない。報告に JSON の例を書いた回が
/// 失敗になる。することが無いという申告が報告として残り、通知が鳴る。
extension AutomationRunnerTests {
  static func agentSink(
    tools: [String] = ["Bash(gh search prs:*)", "mcp__slack__post"],
    request: String = "レビュー待ちの PR を Slack に投稿して", model: String? = nil
  ) -> AutomationSink {
    .agent(AutomationSinkAgent(cli: "claude", model: model, tools: tools, request: request))
  }

  private func agentDefinition(
    sourced: Bool = false, steps: [AutomationStep] = []
  ) -> AutomationDefinition {
    var definition = AutomationStoreTests.definition()
    if !sourced { definition.source = nil }
    definition.steps = steps
    definition.sink = Self.agentSink()
    return definition
  }

  private func agentCall(_ index: Int) -> BackgroundAgentCall? {
    guard jobs.calls.indices.contains(index), case .agent(let call) = jobs.calls[index].job.work
    else { return nil }
    return call
  }

  private func ended(_ ending: BackgroundEnding, reply: String? = nil) -> BackgroundRunResult {
    BackgroundRunResult(
      commandLine: "claude -p", startedAt: now, endedAt: now, ending: ending,
      output: .agent(
        reply: reply.map { BackgroundAgentReply(text: $0, isError: false) },
        stderr: .init(data: Data("boom".utf8))))
  }

  /// 取得元も段も無ければトリガーのたびに起き、名指しの規則・解いたモデル・裏の agent の上限で走る。依頼文は枠と定義の依頼文で、
  /// 「今」は届ける時点の時計。最終応答は回の結果として残る。
  func testWithoutSourceOrStepsTheAgentRunsOnEachTriggerAndItsReplyIsKept() throws {
    let automation = try create(agentDefinition())
    now = automation.createdAt.addingTimeInterval(3600)
    try runner.runNow(automation.id)

    let call = try XCTUnwrap(agentCall(0))
    XCTAssertEqual(call.tools, ["Bash(gh search prs:*)", "mcp__slack__post"])
    XCTAssertEqual(call.model, "sonnet", "省略したモデルは sonnet")
    XCTAssertEqual(jobs.calls[0].job.limits, .agent)
    XCTAssertTrue(call.prompt.contains("レビュー待ちの PR を Slack に投稿して"))
    XCTAssertTrue(call.prompt.contains(#"{"error": "<what went wrong>"}"#))
    XCTAssertTrue(call.prompt.contains("Now: 2027-01-15"), "今は走らせ役の時計")
    jobs.finish(0, replied("\n2 件を投稿した。\n- #1\n- #2\n"))

    let run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertNil(run.failure)
    XCTAssertEqual(
      run.sink,
      .agent(
        AutomationAgentReport(
          commandLine: "claude -p", ending: "exited 0", text: "2 件を投稿した。\n- #1\n- #2")))
    XCTAssertEqual(recorded, [automation.id])
  }

  /// 全体が `{"nothing": …}` の 1 行の応答は、することが無いという申告で、理由を記録に残す。空の応答は文の無い成功。長い応答は
  /// 報告と同じく切る。
  func testANothingLineIsRecordedAndAnEmptyReplyLeavesNoTextAndALongReplyIsCut() throws {
    let automation = try create(agentDefinition())
    try runner.runNow(automation.id)
    XCTAssertTrue(prompt(0).contains(#"{"nothing": "<why>"}"#))
    jobs.finish(0, replied(#" {"nothing": "土曜なので投稿しない"}"# + "\n"))
    var run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertNil(run.failure)
    XCTAssertEqual(
      run.sink,
      .agent(
        AutomationAgentReport(
          commandLine: "claude -p", ending: "exited 0", text: nil, nothing: "土曜なので投稿しない")))

    try runner.runNow(automation.id)
    jobs.finish(1, replied("  \n"))
    run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertNil(run.failure)
    XCTAssertEqual(
      run.sink,
      .agent(AutomationAgentReport(commandLine: "claude -p", ending: "exited 0", text: nil)))

    try runner.runNow(automation.id)
    jobs.finish(2, replied(String(repeating: "あ", count: 2_500)))
    guard case .agent(let report) = store.automation(automation.id)?.runs.first?.sink else {
      return XCTFail("agent の記録")
    }
    XCTAssertEqual(report.text, String(repeating: "あ", count: 2_000) + "…")
  }

  /// 取得元があれば新しい項目が届いた回だけ 1 度起き、項目の本文も件数も依頼文に入らない。新着の無い回は起きずに成功する。
  func testFetchedItemsOnlyGateTheAgentAndNeverReachItsPrompt() throws {
    let automation = try create(agentDefinition(sourced: true))
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a", "b"]))

    XCTAssertEqual(jobs.calls.count, 2, "2 件でも agent は 1 度")
    let prompt = try XCTUnwrap(agentCall(1)?.prompt)
    XCTAssertFalse(prompt.contains("の本文"), "取得した本文を依頼文に入れない")
    XCTAssertFalse(prompt.contains("example.com"), "リンクも入れない")
    XCTAssertFalse(prompt.contains(#""id""#), "行の形のものを入れない")
    jobs.finish(1, replied("投稿した"))
    XCTAssertEqual(store.automation(automation.id)?.runs.first?.fresh, 2)

    try runner.runNow(automation.id)
    jobs.finish(2, fetched(["a", "b"]))
    XCTAssertEqual(jobs.calls.count, 3, "新着の無い回は起こさない")
    let quiet = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertNil(quiet.failure)
    XCTAssertNil(quiet.sink, "起こさなかった回は出力先の記録を持たない")
  }

  /// 最後の段は中間の段と同じ枠で頼まれ、0 行なら起こさずに成功、全行が形違いなら失敗。行が届けば起き、届いた行は依頼文に
  /// 入らない。
  func testTheLastStepGatesTheAgentLikeAMiddleStep() throws {
    let step = AutomationStep(
      name: "絞り込み",
      method: .agent(AutomationStepAgent(cli: "claude", model: nil, instruction: "依頼だけ残す")))
    let automation = try create(agentDefinition(sourced: true, steps: [step]))

    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a"]))
    XCTAssertTrue(prompt(1).contains(#"Keep the "id" of each item you pass on"#), "中間の段の枠")
    jobs.finish(1, replied(#"{"nothing": "依頼は無い"}"#))
    XCTAssertEqual(jobs.calls.count, 2, "段が 0 行を申告した回は起こさない")
    var run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertNil(run.failure)
    XCTAssertNil(run.sink)

    try runner.runNow(automation.id)
    jobs.finish(2, fetched(["a", "b"]))
    jobs.finish(3, replied("not json"))
    run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertEqual(run.failure, "every line of the output of the last step was malformed")
    XCTAssertEqual(jobs.calls.count, 4)

    try runner.runNow(automation.id)
    jobs.finish(4, fetched(["a", "b"]))
    jobs.finish(5, replied(#"{"id":"b","note":"SECRET-ROW"}"#))
    let prompt = try XCTUnwrap(agentCall(6)?.prompt)
    XCTAssertFalse(prompt.contains("SECRET-ROW"), "段が出した行も依頼文に入らない")
    jobs.finish(6, replied("済み"))
    run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertEqual(run.steps.last?.count, 1, "最後の段の数は届いた行の数")
    XCTAssertTrue(run.lastStepCountedBySink)
  }

  /// 応答の全体が `{"error": …}` の 1 行なら出力先で落ちた回で、項目は次の回にもう一度流れる。報告の中に JSON を書いた回は
  /// 失敗にしない。
  func testAnErrorLineFailsTheRunButJSONInsideAReportDoesNot() throws {
    let automation = try create(agentDefinition(sourced: true))
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a"]))
    jobs.finish(1, replied(#"  {"error": "mcp__slack__post was refused"}  "#))

    let failed = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertEqual(failed.failure, "the sink agent reported an error: mcp__slack__post was refused")
    XCTAssertEqual(
      failed.sink,
      .agent(AutomationAgentReport(commandLine: "claude -p", ending: "exited 0", text: nil)),
      "出力先で落ちた印に記録を持つ")
    XCTAssertEqual(store.automation(automation.id)?.lastFetched, [], "項目は次の回にもう一度流れる")

    try runner.runNow(automation.id)
    jobs.finish(2, fetched(["a"]))
    XCTAssertNotNil(agentCall(3), "失敗した回の後はもう一度起きる")
    jobs.finish(3, replied("投稿した。\n{\"error\": \"例\"}"))
    XCTAssertNil(store.automation(automation.id)?.runs.first?.failure)
  }

  /// 落ちた・時間切れ・名指しの MCP ツールが揃わなかった・CLI が失敗を報告した回は、どれも出力先で落ちた回。
  func testACrashedLimitedOrToolLessAgentFailsTheRun() throws {
    let automation = try create(agentDefinition())
    let cases: [(BackgroundRunResult, String)] = [
      (ended(.exited(1)), "the sink ended: exited 1: boom"),
      (
        ended(.limited(.elapsed)),
        "the sink ended: \(BackgroundEnding.limited(.elapsed).text): boom"
      ),
      (
        ended(.toolsUnavailable(["mcp__slack__post"])),
        "the sink ended: tools unavailable: mcp__slack__post: boom"
      ),
      (replied("rate limited", isError: true), "the sink agent reported an error: rate limited"),
    ]
    for (index, (result, reason)) in cases.enumerated() {
      try runner.runNow(automation.id)
      jobs.finish(index, result)
      let run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
      XCTAssertEqual(run.failure, reason)
      guard case .agent(let report) = run.sink else { return XCTFail("出力先で落ちた印: \(reason)") }
      XCTAssertNil(report.text)
    }
  }
}
