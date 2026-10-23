import XCTest

@testable import Orbe

/// 結果に残す実行の記録——受けた数の数え方は役割ごとに決まる。
///
/// 壊れると何が起きるか: 回の記録の件数が渡した行と食い違う（断った件まで「取った」に数える）。
final class AutomationPartPassRecordTests: AutomationPartPassTestCase {
  private var count: Int? { outcomes.first?.execution.count }

  /// 取得は今回取れた全項目を数える（前回の出力にあって下流へ渡さない項目も）。
  func testFetchCountsEveryItemItRead() {
    start(
      AutomationGraphTests.fetch("f"), .fetch, .fetch(since: nil))

    jobs.finish(0, fetched(["a", "b"]))

    XCTAssertEqual(count, 2, "\(outcomes)")
  }

  func testProcessAndJudgeCountTheLinesTheyGave() {
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

  /// agent は受けた件数を数える（断った呼び出しの件は数えない）。
  func testAgentCountsWhatWasAccepted() {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a"), row("b")], reachesJudge: false))

    readAll(0)
    use(0, .putRows, ["rows": [["id": "f:a"], ["note": "x"]]])
    use(0, .putRows, ["rows": [["id": "f:a"]]])
    use(0, .putRows, ["rows": [["id": "f:b"]]])
    jobs.finish(0, done())

    XCTAssertEqual(count, 2, "\(outcomes)")
  }
}
