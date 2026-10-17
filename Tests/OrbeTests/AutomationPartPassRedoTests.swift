import XCTest

@testable import Orbe

/// 決まりを外した出力——agent は 1 回だけ、ツール無しで、上限の残りの中で出し直させ、外れた行をすべて依頼文に載せる。通れば
/// 出し直しの出力で成功し、まだ外れていれば失敗で何も渡さない。コマンドは出し直さない。申告のエラーは出し直さない。
///
/// 壊れると何が起きるか: 出し直しがツールを持ち、前の出力に入った外の文面でツールが動く。出し直しで回が上限の 2 倍まで延びる。
/// 直させたい行が依頼文から漏れて出し直しが通らない。同じコマンドを走らせ直して時間を倍使う。止めた回の出し直しが走り続ける。
final class AutomationPartPassRedoTests: AutomationPartPassTestCase {
  /// agent の出し直しは 1 回で、ツールを持たず、上限は 1 回目の残り。依頼文には元の依頼文・前の出力・外れた行のすべてが載る。
  /// 通れば出し直しの出力で成功し、外したことが付く。
  func testAgentOutputThatBreaksTheRulesIsRedoneOnceWithoutTools() throws {
    start(
      AutomationGraphTests.agent(
        "f", tools: [Self.tool], deliver: .nextPart, coverage: .currentSet),
      .fetch(.currentSet), .fetch(since: nil, lastOutput: []))
    let first = (1...6).map { #"{"id":"x\#($0)"}"# }.joined(separator: "\n")

    jobs.finish(0, replied(first, took: 200))

    let redo = try XCTUnwrap(agentCall(1), "\(jobs.calls.count)")
    XCTAssertEqual(redo.tools, [])
    XCTAssertEqual(jobs.calls[1].job.limits.elapsed, 400, "上限は 2 回で分け合う")
    XCTAssertNil(jobs.calls[1].job.limits.idle)
    XCTAssertTrue(redo.prompt.contains(try XCTUnwrap(agentCall(0)).prompt), "元の依頼文")
    XCTAssertTrue(redo.prompt.contains(first), "前の出力")
    for line in 1...6 {
      XCTAssertTrue(redo.prompt.contains("line \(line): missing link"), "外れた行はすべて載る")
    }

    XCTAssertTrue(redo.prompt.contains("Do not add items"), "取り直せないので、項目を作らせない")

    jobs.finish(
      1,
      replied(
        #"{"id":"a","link":"https://example.com/a","body":"a","time":"2026-10-10T09:00:00Z"}"#))

    guard case .fetch(let rows, _) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(rows.map(\.id), ["f:a"])
    XCTAssertEqual(breach?.lines.count, 6)
    XCTAssertEqual(breach?.redo?.lines, [])
  }

  /// 出し直しでも外れていれば失敗で、何も渡さない。失敗の文は出し直しの出力の行を言う。
  func testRedoThatStillBreaksTheRulesFails() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], feedsJudge: false))

    jobs.finish(0, replied(#"{"note":"id を落とした"}"#))
    jobs.finish(1, replied(#"{"id":"f:a"}"# + "\n" + #"{"note":"まだ落とした"}"#))

    XCTAssertTrue(try XCTUnwrap(failed, "\(outcomes)").contains("line 2"), "定義を直せるよう、どの行かを言う")
    XCTAssertEqual(breach?.lines.map(\.line), [1])
    XCTAssertEqual(breach?.redo?.lines.map(\.line), [2])
    XCTAssertEqual(jobs.calls.count, 2, "出し直しは 1 回だけ")
  }

  /// コマンドは同じ出力を繰り返すだけなので、出し直さずに直ちに失敗する。
  func testCommandOutputThatBreaksTheRulesFailsWithoutARedo() throws {
    start(
      AutomationGraphTests.command("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], feedsJudge: false))

    jobs.finish(0, printed(#"{"id":"f:a"}"# + "\n" + #"{"note":"id を落とした"}"#))

    XCTAssertTrue(try XCTUnwrap(failed, "\(outcomes)").contains("line 2"))
    XCTAssertEqual(jobs.calls.count, 1)
    XCTAssertNil(breach?.redo)
  }

  /// 1 回目が上限を使い切ったら出し直さない——出し直すと回が上限を超えて延びる。
  func testNoRedoWhenTheFirstCallUsedUpTheTime() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], feedsJudge: false))

    jobs.finish(0, replied(#"{"note":"id を落とした"}"#, took: 600))

    XCTAssertEqual(jobs.calls.count, 1)
    XCTAssertNotNil(failed, "\(outcomes)")
    XCTAssertEqual(breach?.lines.count, 1)
  }

  /// 上限の残りは上限と同じ時計（スリープ中を数えない）で測る——回の途中で Mac が眠っても、残りを少なく見積もらない。
  func testRedoTimeLeftExcludesSleepDuringTheFirstCall() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], feedsJudge: false))

    jobs.finish(
      0,
      BackgroundRunResult(
        commandLine: "claude -p", startedAt: now, endedAt: now.addingTimeInterval(3600),
        elapsed: 200, ending: .exited(0),
        output: .agent(
          reply: BackgroundAgentReply(text: #"{"note":"id を落とした"}"#, isError: false),
          stderr: .init())))

    XCTAssertEqual(jobs.calls.count, 2, "眠っていた 1 時間は上限に数えない")
    XCTAssertEqual(jobs.calls[1].job.limits.elapsed, 400)
  }

  /// 取得の `{"error": …}` は申告の失敗で、形を外したのではない——出し直さない。
  func testFetchReportingAnErrorFailsWithoutARedo() throws {
    start(
      AutomationGraphTests.agent(
        "f", tools: [Self.tool], deliver: .nextPart, coverage: .currentSet),
      .fetch(.currentSet), .fetch(since: nil, lastOutput: []))

    jobs.finish(0, replied(#"{"error":"Slack に届かない"}"#))

    XCTAssertTrue(try XCTUnwrap(failed, "\(outcomes)").contains("Slack に届かない"))
    XCTAssertEqual(jobs.calls.count, 1)
    XCTAssertNil(breach)
  }

  /// 出し直しの間に止めたら、出し直しの呼び出しを止め、結果は返さない。
  func testStoppingDuringARedoStopsTheRedo() {
    let handle = start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], feedsJudge: false))
    jobs.finish(0, replied(#"{"note":"id を落とした"}"#))

    handle.stop()
    jobs.finish(1, replied(#"{"id":"f:a"}"#))

    XCTAssertEqual(jobs.stopped, [1])
    XCTAssertEqual(outcomes, [])
  }
}
