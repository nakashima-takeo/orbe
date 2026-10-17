import OrbeSessionLog
import XCTest

@testable import Orbe

/// 部品の 1 回——役割どおりに手段を起こし（上限・目印・標準入力・回の ID・ツール）、役割ごとに出力を読む（取得の差分と接頭と
/// 出どころ、処理の出どころの照らし、判定の候補の出どころ、仕事と副作用の失敗）。決まりを外した出力は、agent なら 1 回だけ
/// ツール無しで出し直させ、コマンドなら失敗にする（出し直しの流れは `AutomationPartPassRedoTests`）。止めた回は何も返さない。
///
/// 壊れると何が起きるか: 長く黙って考える agent が途中で切られる。今の集合の取得が前回以降の分だけを取り、候補が一斉に下がる。
/// 副作用のやり直しに回の ID が渡らず二重に起きる。仕事の agent がツール無しで起き、何もせずに成功する。前回取れた項目が
/// 毎回流れ直す、または出どころの id が接頭付きになり前回の出力と照らせない。照らせない・重なった・nothing と一緒に出た
/// 処理の行や、地の文だけの判定が黙って消える。候補の無い判定の回が失敗になる。候補に別の項目のリンクが付く。失敗した取得・
/// 仕事・副作用が成功として確定する。止めた回の結果が書き換えた後の定義で確定する。
final class AutomationPartPassTests: AutomationPartPassTestCase {
  // MARK: - 起こし方

  /// 上限は部品の経過時間だけで、無出力では打ち切らない——黙って長く考える agent を切らないため。
  func testPartIsLimitedOnlyByItsTimeoutNotBySilence() {
    var part = AutomationGraphTests.agent("r", from: ["f"])
    part.timeoutMinutes = 3

    start(part, .report, .report([]))

    XCTAssertEqual(jobs.calls[0].job.limits.elapsed, 180)
    XCTAssertNil(jobs.calls[0].job.limits.idle)
  }

  /// 前回成功の目印は新着の流れの取得にだけ渡る。今の集合に渡すと前回以降の分だけが取れ、取得から消えたものとして候補が下がる。
  func testOnlyNewArrivalsFetchGetsTheMark() throws {
    let since = now.addingTimeInterval(-3600)

    start(
      AutomationGraphTests.fetch("f", .newArrivals), .fetch(.newArrivals),
      .fetch(since: since, lastOutput: []))
    start(
      AutomationGraphTests.fetch("f", .currentSet), .fetch(.currentSet),
      .fetch(since: since, lastOutput: []))

    XCTAssertEqual(
      try XCTUnwrap(commandInput(0)).environment, ["ORBE_SINCE": SessionEvent.iso8601(since)])
    XCTAssertEqual(try XCTUnwrap(commandInput(1)).environment, [:])
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

  func testWorkAgentRunsWithItsTools() throws {
    start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work)

    guard case .agent(let call) = jobs.calls[0].job.work else { return XCTFail("仕事は agent") }
    XCTAssertEqual(call.tools, [Self.tool])
  }

  // MARK: - 取得

  /// 前回の出力に無い項目だけを渡す。渡す行の `id` は `<鍵>:<元の id>`、出どころは元の項目のまま。前回の出力は今回の全項目。
  func testFetchPassesOnlyItemsMissingFromTheLastOutput() throws {
    start(
      AutomationGraphTests.fetch("f"), .fetch(.currentSet), .fetch(since: nil, lastOutput: ["a"]))

    jobs.finish(0, fetched(["a", "b"]))

    guard case .fetch(let rows, let lastOutput) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(rows.map(\.id), ["f:b"])
    XCTAssertEqual(rows.map { AutomationPrompts.id(of: $0.text) }, ["f:b"])
    XCTAssertEqual(rows.first?.origin?.part, "f")
    XCTAssertEqual(rows.first?.origin?.item.id, "b", "前回の出力と照らせるよう、出どころの id は接頭の無い元の id")
    XCTAssertEqual(
      lastOutput,
      [
        AutomationSeen(id: "a", link: "https://example.com/a"),
        AutomationSeen(id: "b", link: "https://example.com/b"),
      ])
  }

  func testEverythingFetchPassesAllItemsRegardlessOfTheLastOutput() throws {
    start(
      AutomationGraphTests.fetch("f", .everything), .fetch(.everything),
      .fetch(since: nil, lastOutput: ["a"]))

    jobs.finish(0, fetched(["a", "b"]))

    guard case .fetch(let rows, _) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(rows.map(\.id), ["f:a", "f:b"])
  }

  /// ツールが揃わず止まった取得は失敗——0 件と読むと、今の集合の候補が一斉に下がる。
  func testFetchThatCouldNotGetItsToolsFails() throws {
    start(
      AutomationGraphTests.agent(
        "f", tools: [Self.tool], deliver: .nextPart, coverage: .currentSet),
      .fetch(.currentSet), .fetch(since: nil, lastOutput: ["a"]))

    jobs.finish(
      0,
      BackgroundRunResult(
        commandLine: "claude -p", startedAt: now, endedAt: now,
        ending: .toolsUnavailable([Self.tool]), output: .agent(reply: nil, stderr: .init())))

    XCTAssertNotNil(failed, "\(outcomes)")
  }

  // MARK: - 処理

  /// nothing の 1 行だけなら、正しい 0 行。
  func testProcessOutputOfOnlyANothingLinePassesNoRows() throws {
    start(
      AutomationGraphTests.command("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], feedsJudge: false))

    jobs.finish(0, printed(#"{"nothing":"残る項目が無い"}"#))

    XCTAssertEqual(succeeded, .process([]), "\(outcomes)")
    XCTAssertNil(breach)
  }

  /// nothing の前の地の文は外れた行——依頼文は地の文を出さないよう言っており、受け付けない行を黙って捨てない。
  func testProseBeforeANothingLineBreaksTheRules() throws {
    start(
      AutomationGraphTests.command("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], feedsJudge: false))

    jobs.finish(0, printed("どれも条件に合いませんでした。\n" + #"{"nothing":"残る項目が無い"}"#))

    XCTAssertEqual(breach?.lines.map(\.line), [1], "\(outcomes)")
    XCTAssertNotNil(failed)
  }

  /// 項目と一緒に出た nothing の行は外れた行——0 行と読むと、一緒に出た項目が黙って消える。
  func testNothingLineAlongsideItemsBreaksTheRules() throws {
    start(
      AutomationGraphTests.command("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], feedsJudge: false))

    jobs.finish(0, printed(#"{"id":"f:a"}"# + "\n" + #"{"nothing":"b は外した"}"#))

    XCTAssertEqual(breach?.lines.map(\.line), [2], "\(outcomes)")
    XCTAssertNotNil(failed)
  }

  /// 出力の行は `id` で入力の行と照らして出どころを引き継ぎ、照らせない行は出どころを持たない。
  func testProcessCarriesTheOriginById() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a"), row("b")], feedsJudge: false))

    jobs.finish(0, replied(#"{"id":"f:b","note":"x"}"# + "\n" + #"{"id":"new"}"#))

    guard case .process(let rows) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(rows.map(\.id), ["f:b", "new"])
    XCTAssertEqual(rows.map(\.origin), [origin("b"), nil])
  }

  /// 判定へ渡す処理の行は、どれも入力の行と `id` で照らせなければならない——照らせない行は判定の溜まりに積めず、黙って消える。
  func testProcessFeedingAJudgeBreaksTheRulesWithARowItCannotTrace() throws {
    start(
      AutomationGraphTests.command("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], feedsJudge: true))

    jobs.finish(0, printed(#"{"id":"f:a"}"# + "\n" + #"{"id":"new"}"#))

    XCTAssertEqual(breach?.lines.map(\.line), [2], "\(outcomes)")
    XCTAssertNotNil(failed)
  }

  /// 同じ `id` の 2 つ目の行は外れた行——積むときに前の行を置き換え、前の行が黙って消える。
  func testProcessRowWithARepeatedIdBreaksTheRules() throws {
    start(
      AutomationGraphTests.command("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], feedsJudge: false))

    jobs.finish(0, printed(#"{"id":"f:a"}"# + "\n" + #"{"id":"f:a","note":"2 度目"}"#))

    XCTAssertEqual(breach?.lines.map(\.line), [2], "\(outcomes)")
  }

  // MARK: - 判定

  /// 候補の案には指した行の出どころが付く。
  func testJudgeProposalsCarryTheOriginOfTheRowTheyPointTo() throws {
    start(
      AutomationGraphTests.agent("j", from: ["f"], deliver: .taskCandidates), .judge,
      judgeInput(["a", "b"]))

    jobs.finish(0, replied(#"{"propose":"f:b","title":"b に返信する"}"#))

    guard case .judge(let proposals, _) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(
      proposals,
      [AutomationPartPass.Proposal(origin: origin("b"), title: "b に返信する", due: nil, workspace: nil)]
    )
    XCTAssertNil(breach)
  }

  /// 地の文だけの応答は、候補なしの成功ではなく決まりを外した出力——判定が壊れても気づけるように。
  func testJudgeReplyOfOnlyProseBreaksTheRules() throws {
    start(
      AutomationGraphTests.agent("j", from: ["f"], deliver: .taskCandidates), .judge,
      judgeInput(["a"]))

    jobs.finish(0, replied("タスクにすべき項目はありません。"))

    XCTAssertEqual(jobs.calls.count, 2, "出し直させる")
    XCTAssertEqual(outcomes, [])
  }

  /// 何も出さない判定は、候補なしの正しい成功——候補にすべき項目が無い回のたびに失敗しない。
  func testJudgeOutputOfNothingSucceedsWithoutCandidates() throws {
    start(
      AutomationGraphTests.command("j", from: ["f"], deliver: .taskCandidates), .judge,
      judgeInput(["a"]))

    jobs.finish(0, printed(""))

    XCTAssertEqual(succeeded, .judge(proposals: [], resolved: []), "\(outcomes)")
    XCTAssertNil(breach)
  }

  /// 取った行に無い `id`（接頭の無い元の `id` を含む）への案は外れた行。
  func testJudgeProposalForAnIdOutsideTheRowsBreaksTheRules() throws {
    start(
      AutomationGraphTests.command("j", from: ["f"], deliver: .taskCandidates), .judge,
      judgeInput(["a"]))

    jobs.finish(0, printed(#"{"propose":"a","title":"a"}"#))

    XCTAssertEqual(breach?.lines.map(\.line), [1], "\(outcomes)")
    XCTAssertNotNil(failed)
  }

  // MARK: - 仕事・副作用

  /// 応答が `{"error": …}` の 1 行だけなら、仕事は失敗。
  func testWorkReplyThatIsOnlyAnErrorFails() throws {
    start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work)

    jobs.finish(0, replied(#"{"error":"投稿できなかった"}"#))

    XCTAssertTrue(try XCTUnwrap(failed, "\(outcomes)").contains("投稿できなかった"))
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

  /// 止めた回は、手段が後から終わっても結果を返さない。
  func testStoppedPassNeverReturnsAResult() {
    let handle = start(
      AutomationGraphTests.fetch("f"), .fetch(.currentSet), .fetch(since: nil, lastOutput: []))

    handle.stop()
    jobs.finish(0, fetched(["a"]))

    XCTAssertEqual(jobs.stopped, [0])
    XCTAssertEqual(outcomes, [])
  }
}
