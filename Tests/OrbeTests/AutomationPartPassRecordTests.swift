import XCTest

@testable import Orbe

/// 結果に残す実行の記録——読めた数の数え方は役割ごとに決まり、記録は出力を使った（最後に読んだ）呼び出しのもの。出し直したなら
/// 1 回目の記録は外したことの側に残る。
///
/// 壊れると何が起きるか: 回の記録の件数が渡した行と食い違う（1 回目が全行外れ・出し直しで取れた回が「0 件取った」になる）。
/// 出し直しが読む前に落ちた回に、出し直したことと落ちた終わり方が残らない。
final class AutomationPartPassRecordTests: AutomationPartPassTestCase {
  private var count: Int? { outcomes.first?.execution.count }

  /// 取得は今回取れた全項目を数える（前回の出力にあって下流へ渡さない項目も）。
  func testFetchCountsEveryItemItRead() {
    start(
      AutomationGraphTests.fetch("f"), .fetch(.currentSet), .fetch(since: nil, lastOutput: ["a"]))

    jobs.finish(0, fetched(["a", "b"]))

    XCTAssertEqual(count, 2, "\(outcomes)")
  }

  func testProcessAndJudgeCountTheJSONLinesTheyRead() {
    start(
      AutomationGraphTests.command("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a"), row("b")], reachesJudge: false))
    start(
      AutomationGraphTests.command("j", from: ["f"], deliver: .taskCandidates), .judge,
      judgeInput(["a", "b"]))

    jobs.finish(0, printed(#"{"id":"f:a"}"# + "\n" + #"{"id":"f:b"}"#))
    jobs.finish(1, printed(#"{"propose":"f:a","title":"a"}"#))

    XCTAssertEqual(outcomes.map(\.execution.count), [2, 1], "\(outcomes)")
  }

  /// 副作用は標準入力に渡した行を数える。
  func testSideEffectCountsTheRowsItWasGiven() {
    start(
      AutomationGraphTests.command("s", from: ["f"]), .sideEffect,
      .sideEffect([row("a"), row("b")], runId: "7-s-1"))

    jobs.finish(0, printed(""))

    XCTAssertEqual(count, 2, "\(outcomes)")
  }

  /// 出し直しで通った回の記録は出し直しの呼び出しのもの——1 回目が全行外れでも、渡した行の数と記録が食い違わない。
  func testRedoneRunRecordsTheRedoAndKeepsTheFirstCallInTheBreach() throws {
    start(
      AutomationGraphTests.agent(
        "f", tools: [Self.tool], deliver: .nextPart, coverage: .currentSet),
      .fetch(.currentSet), .fetch(since: nil, lastOutput: []))

    jobs.finish(0, replied(#"{"id":"x"}"#))
    jobs.finish(
      1,
      replied(
        #"{"id":"a","link":"https://example.com/a","body":"a","time":"2026-10-10T09:00:00Z"}"#))

    guard case .fetch(let rows, _) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(count, 1)
    XCTAssertEqual(breach?.redo?.firstCall.count, 0)
  }

  /// 出し直しが読む前に落ちた回も、記録は出し直しの終わり方で、出し直したことが残る。
  func testRedoThatEndsBeforeItIsReadRecordsItsEnding() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], reachesJudge: false))

    jobs.finish(0, replied(#"{"note":"id を落とした"}"#))
    jobs.finish(
      1,
      BackgroundRunResult(
        commandLine: "claude -p", startedAt: now, endedAt: now, elapsed: 0,
        ending: .limited(.elapsed), output: .agent(reply: nil, stderr: .init())))

    XCTAssertNotNil(failed, "\(outcomes)")
    XCTAssertEqual(outcomes.first?.execution.ending, BackgroundEnding.limited(.elapsed).text)
    XCTAssertEqual(breach?.redo?.lines, [])
    XCTAssertEqual(breach?.redo?.firstCall.count, 1)
  }
}
