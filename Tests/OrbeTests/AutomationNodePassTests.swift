import OrbeSessionLog
import XCTest

@testable import Orbe

/// 部品の 1 回——役割どおりに手段を起こし（上限・目印・標準入力・回の ID・ツール・Orbe の口）、役割ごとに結果を受ける（取得の
/// 書かれたままの行、処理の出どころの照らし、判定の候補の出どころ、仕事と副作用の失敗）。agent は Orbe の MCP の道具で、
/// コマンドは標準出力で、同じ決まりで受ける（道具の答えは `AutomationRunSessionTests`）。止めた回は何も返さない。
///
/// 壊れると何が起きるか: 部品が、利用者の決めた上限時間より前に出力が無いという理由で切られる。今の集合の取得が前回以降の
/// 分だけを取り、候補が一斉に下がる。副作用のやり直しに回の ID が渡らず二重に起きる。仕事の agent がツール無しで起き、何も
/// せずに成功する。前回取れた項目が毎回流れ直す。照らせない・重なった処理の行が黙って消える。結果を出さずに終えた agent の回が
/// 成功になる。候補に別の項目のリンクが付く。失敗した取得・仕事・副作用が成功として確定する。止めた回の結果が書き換えた後の
/// 定義で確定する。
final class AutomationNodePassTests: AutomationNodePassTestCase {
  // MARK: - 起こし方

  /// 上限は部品の経過時間だけで、無出力では打ち切らない——部品の上限は利用者が決める `timeoutMinutes` の一本にするため。
  func testPartIsLimitedOnlyByItsTimeoutNotBySilence() {
    var part = AutomationGraphTests.agent("r", from: ["f"])
    part.action.timeoutMinutes = 3

    start(part, .report, .report([]))

    XCTAssertEqual(jobs.calls[0].job.limits.elapsed, 180)
    XCTAssertNil(jobs.calls[0].job.limits.idle)
  }

  /// 前回成功の目印は新着の流れの取得にだけ渡る（コマンドは `ORBE_SINCE`、agent は依頼文）。今の集合に渡すと前回以降の分だけが
  /// 取れ、取得から消えたものとして候補が下がる。
  func testOnlyNewArrivalsFetchGetsTheMark() throws {
    let since = now.addingTimeInterval(-3600)
    let mark = SessionEvent.iso8601(since)
    func agent(_ coverage: AutomationCoverage) -> AutomationDefinition.Node {
      AutomationGraphTests.agent("f", tools: [Self.tool], deliver: .nextPart, coverage: coverage)
    }

    start(
      AutomationGraphTests.fetch("f", .newArrivals), .fetch,
      .fetch(since: since))
    start(
      AutomationGraphTests.fetch("f", .currentSet), .fetch,
      .fetch(since: since))
    start(agent(.newArrivals), .fetch, .fetch(since: since))
    start(agent(.currentSet), .fetch, .fetch(since: since))

    XCTAssertEqual(try XCTUnwrap(commandInput(0)).environment, ["ORBE_SINCE": mark])
    XCTAssertEqual(try XCTUnwrap(commandInput(1)).environment, [:])
    XCTAssertTrue(try XCTUnwrap(agentCall(2)).prompt.contains(mark))
    XCTAssertFalse(try XCTUnwrap(agentCall(3)).prompt.contains(mark))
  }

  /// 副作用のコマンドは取った行を 1 行 1 オブジェクトで標準入力に受け、回の ID を `ORBE_RUN_ID` で受ける。
  func testSideEffectCommandReceivesRowsOnStdinAndTheRunId() throws {
    start(
      AutomationGraphTests.command("s", from: ["f"]), .sideEffect,
      .sideEffect([row("a"), row("b")], runId: "7-s-1"))

    let input = try XCTUnwrap(commandInput(0))
    XCTAssertEqual(input.stdin, Data("{\"id\":\"f:a\"}\n{\"id\":\"f:b\"}\n".utf8))
    XCTAssertEqual(input.environment, ["ORBE_RUN_ID": "7-s-1"])
  }

  /// 仕事の agent は自分のツールと、結果を出す Orbe の口を持つ。
  func testWorkAgentRunsWithItsToolsAndOrbesResultTools() throws {
    start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work)

    let call = try XCTUnwrap(agentCall(0), "仕事は agent")
    XCTAssertEqual(call.tools, [Self.tool])
    XCTAssertEqual(call.orbe?.tools, ["put_report", "report_nothing", "report_error"])
  }

  /// 役割ごとに、Orbe の口で出す道具が決まる（行を見る部品は行がある回だけ読む道具を持つ）。
  func testEachRoleGetsItsTools() throws {
    start(
      AutomationGraphTests.agent(
        "f", tools: [Self.tool], deliver: .nextPart, coverage: .currentSet),
      .fetch, .fetch(since: nil))
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], reachesJudge: false))
    start(
      AutomationGraphTests.agent("j", from: ["f"], deliver: .taskCandidates), .judge,
      judgeInput(["a"]))
    start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([]))

    XCTAssertEqual(agentCall(0)?.orbe?.tools, ["put_items", "report_nothing", "report_error"])
    XCTAssertEqual(agentCall(1)?.orbe?.tools, ["read_run_rows", "put_rows", "report_nothing"])
    XCTAssertEqual(
      agentCall(2)?.orbe?.tools,
      [
        "read_run_rows", "read_waiting_proposals", "read_workspaces", "propose", "resolve",
        "report_nothing",
      ])
    XCTAssertEqual(agentCall(3)?.orbe?.tools, ["put_report", "report_nothing"])
  }

  // MARK: - 取得

  /// 取れた全項目を、書かれた id と書かれたままの 1 行（余分な欄も残す）で返す。何が新しいかは出す側の確定が決める。
  func testFetchReturnsEveryItemAsWritten() throws {
    start(AutomationGraphTests.fetch("f"), .fetch, .fetch(since: nil))
    let labelled =
      #"{"id":"b","link":"https://example.com/b","body":"b","time":"2026-10-10T09:00:00Z","labels":["x"]}"#

    jobs.finish(0, printed(fetchedLine("a") + "\n" + labelled))

    guard case .fetch(let rows) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(rows.map(\.id), ["a", "b"])
    XCTAssertEqual(rows.last?.text, labelled, "書かれたまま")
    XCTAssertEqual(rows.map(\.source), [nil, nil])
  }

  private func fetchedLine(_ id: String) -> String {
    #"{"id":"\#(id)","link":"https://example.com/\#(id)","body":"\#(id) の本文","time":"2026-10-10T09:00:00Z"}"#
  }

  /// 取得の agent は項目を道具で出し、受けた項目が結果になる（最終応答の文は読まない）。
  func testFetchAgentGivesItsItemsThroughTheTool() throws {
    start(
      AutomationGraphTests.agent(
        "f", tools: [Self.tool], deliver: .nextPart, coverage: .currentSet),
      .fetch, .fetch(since: nil))

    use(
      0, .putItems,
      [
        "items": [
          [
            "id": "a", "link": "https://example.com/a", "body": "a", "time": "2026-10-10T09:00:00Z",
          ]
        ]
      ])
    jobs.finish(0, replied("取れました。"))

    guard case .fetch(let rows) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(rows.map(\.id), ["a"])
    XCTAssertEqual(outcomes.first?.execution.count, 1)
  }

  /// 同じ `id` の 2 つ目の項目は外れた件で、コマンドの取得はその回を失敗にする。
  func testFetchItemWithARepeatedIdBreaksTheRules() throws {
    start(AutomationGraphTests.fetch("f"), .fetch, .fetch(since: nil))

    jobs.finish(0, fetched(["a", "a"]))

    XCTAssertEqual(breach?.lines.map(\.line), [2], "\(outcomes)")
    XCTAssertNotNil(failed, "コマンドの取得は外れた件があれば失敗")
  }

  /// ツールが揃わず止まった取得は失敗——0 件と読むと、今の集合の候補が一斉に下がる。
  func testFetchThatCouldNotGetItsToolsFails() throws {
    start(
      AutomationGraphTests.agent(
        "f", tools: [Self.tool], deliver: .nextPart, coverage: .currentSet),
      .fetch, .fetch(since: nil))

    jobs.finish(
      0,
      BackgroundRunResult(
        commandLine: "claude -p", startedAt: now, endedAt: now,
        ending: .toolsUnavailable([Self.tool]), output: .agent(reply: nil, stderr: .init())))

    XCTAssertNotNil(failed, "\(outcomes)")
  }

  /// 取得の agent が失敗を申告した回は失敗——0 件と読むと、今の集合の候補が一斉に下がる。
  func testFetchReportingAnErrorFails() throws {
    start(
      AutomationGraphTests.agent(
        "f", tools: [Self.tool], deliver: .nextPart, coverage: .currentSet),
      .fetch, .fetch(since: nil))

    use(0, .reportError, ["what": "Slack に届かない"])
    jobs.finish(0, done())

    XCTAssertEqual(failed, #"the part "f" reported an error: Slack に届かない"#)
  }

  // MARK: - 処理

  /// 出力の行は `id` で入力の行と照らして、その入力（出す側の行）と出どころを引き継ぎ、照らせない行はどちらも持たない。
  func testProcessCarriesTheOriginById() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a"), row("b")], reachesJudge: false))

    readAll(0)
    use(0, .putRows, ["rows": [["id": "f:b", "note": "x"], ["id": "new"]]])
    jobs.finish(0, done())

    guard case .process(let rows) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(rows.map(\.id), ["f:b", "new"])
    XCTAssertEqual(rows.map(\.origin), [origin("b"), nil])
    XCTAssertEqual(rows.map(\.source), [row("b").source, nil])
  }

  /// 取得 → 処理 a → 処理 b → 判定 では、a の行も判定へ届く。照らせない行は判定で使えず黙って消えるので、それを初めに出した
  /// a が外したことになる——下流の b には直しようがない。
  func testProcessWhoseRowsReachAJudgeBreaksTheRulesWithARowItCannotTrace() throws {
    let parts = [
      AutomationGraphTests.fetch("f"),
      AutomationGraphTests.command("a", from: ["f"], deliver: .nextPart),
      AutomationGraphTests.command("b", from: ["a"], deliver: .nextPart),
      AutomationGraphTests.agent("j", from: ["b"], deliver: .taskCandidates),
    ]
    let graph = try AutomationGraph.numbered(parts)
    let a = try XCTUnwrap(graph.node(key: "a"))
    start(parts[1], a.role, .process([row("a")], reachesJudge: graph.reachesTaskCandidates(a.id)))

    jobs.finish(0, printed(#"{"id":"f:a"}"# + "\n" + #"{"id":"new"}"#))

    XCTAssertEqual(breach?.lines.map(\.line), [2], "\(outcomes)")
    XCTAssertNotNil(failed)
  }

  /// 同じ `id` の 2 つ目の行は外れた件——前の行を置き換え、前の行が黙って消える。
  func testProcessRowWithARepeatedIdBreaksTheRules() throws {
    start(
      AutomationGraphTests.command("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], reachesJudge: false))

    jobs.finish(0, printed(#"{"id":"f:a"}"# + "\n" + #"{"id":"f:a","note":"2 度目"}"#))

    XCTAssertEqual(breach?.lines.map(\.line), [2], "\(outcomes)")
  }

  // MARK: - 判定

  /// 候補の案には指した行の出どころが付く。
  func testJudgeProposalsCarryTheOriginOfTheRowTheyPointTo() throws {
    start(
      AutomationGraphTests.agent("j", from: ["f"], deliver: .taskCandidates), .judge,
      judgeInput(["a", "b"]))

    readAll(0)
    use(0, .propose, ["proposals": [["id": "f:b", "title": "b に返信する"]]])
    jobs.finish(0, done())

    guard case .judge(let proposals, _) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(
      proposals,
      [
        AutomationNodePass.Proposal(
          origin: origin("b"), title: "b に返信する", due: nil, workspace: nil, reason: nil)
      ]
    )
    XCTAssertNil(breach)
  }

  /// 何も出さないコマンドの判定は、候補なしの正しい成功——候補にすべき項目が無い回のたびに失敗しない。
  func testJudgeOutputOfNothingSucceedsWithoutCandidates() throws {
    start(
      AutomationGraphTests.command("j", from: ["f"], deliver: .taskCandidates), .judge,
      judgeInput(["a"]))

    jobs.finish(0, printed(""))

    XCTAssertEqual(succeeded, .judge(proposals: [], resolved: []), "\(outcomes)")
    XCTAssertNil(breach)
  }

  /// 取った行に無い `id`（接頭の無い元の `id` を含む）への案は外れた件。
  func testJudgeProposalForAnIdOutsideTheRowsBreaksTheRules() throws {
    start(
      AutomationGraphTests.command("j", from: ["f"], deliver: .taskCandidates), .judge,
      judgeInput(["a"]))

    jobs.finish(0, printed(#"{"propose":"a","title":"a"}"#))

    XCTAssertEqual(breach?.lines.map(\.line), [1], "\(outcomes)")
    XCTAssertNotNil(failed)
  }

  // MARK: - 仕事・副作用

  /// 仕事が失敗を申告した回は失敗。
  func testWorkReportingAnErrorFails() throws {
    start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work)

    use(0, .reportError, ["what": "投稿できなかった"])
    jobs.finish(0, done())

    XCTAssertTrue(try XCTUnwrap(failed, "\(outcomes)").contains("投稿できなかった"))
  }

  /// agent が終了コード 0 でもエラーを返した回（is_error）は失敗で、受けた結果も使わない。
  func testAnAgentReplyMarkedAsAnErrorFails() throws {
    start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work)

    use(0, .putReport, ["text": "投稿した"])
    jobs.finish(0, replied("rate limited", isError: true))

    XCTAssertTrue(try XCTUnwrap(failed, "\(outcomes)").contains("reported an error"))
  }

  /// 副作用は終了コードで成否が決まり、失敗には標準エラーが添えられる。
  func testSideEffectFailsByItsExitCode() throws {
    start(
      AutomationGraphTests.command("s", from: ["f"]), .sideEffect,
      .sideEffect([row("a")], runId: "7-s-1"))

    jobs.finish(0, printed("", exit: 1, stderr: "rate limited"))

    XCTAssertTrue(try XCTUnwrap(failed, "\(outcomes)").contains("rate limited"))
  }

  // MARK: - 止める

  /// 止めた回は、手段が後から終わっても結果を返さず、agent の回の口も閉じる。
  func testStoppedPassNeverReturnsAResult() {
    let handle = start(
      AutomationGraphTests.fetch("f"), .fetch, .fetch(since: nil))
    let agentHandle = start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work)

    handle.stop()
    agentHandle.stop()
    jobs.finish(0, fetched(["a"]))
    jobs.finish(1, done())

    XCTAssertEqual(jobs.stopped, [0, 1])
    XCTAssertEqual(outcomes, [])
    XCTAssertNil(session(1), "止めた回の札は断る")
  }
}
