import XCTest

@testable import Orbe

/// コマンドの何も無い回と失敗の言い方、agent の結果の無い回と断った結果（`AutomationPartPassTests` の続き）。
extension AutomationPartPassTests {
  // MARK: - コマンドの空の出力と終了コード

  /// コマンドの何も無い回は空の出力——正しい 0 件。
  func testEmptyCommandOutputIsNothing() throws {
    start(
      AutomationGraphTests.command("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], reachesJudge: false))

    jobs.finish(0, printed(""))

    XCTAssertEqual(succeeded, .process([]), "\(outcomes)")
    XCTAssertNil(breach)
  }

  /// コマンドの失敗は 0 以外の終了コード。`{"error": …}` も `{"nothing": …}` も申告ではなく、ただの行として確かめる。
  func testCommandFailsByExitCodeAndDeclarationLinesAreJustLines() throws {
    start(AutomationGraphTests.fetch("f"), .fetch(.currentSet), .fetch(since: nil))
    start(
      AutomationGraphTests.command("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], reachesJudge: false))

    jobs.finish(0, printed(#"{"error":"down"}"#, exit: 2, stderr: "down"))
    jobs.finish(1, printed(#"{"nothing":"無い"}"#))

    XCTAssertEqual(outcomes.count, 2)
    guard case .failed(.ended, _, _) = outcomes[0] else { return XCTFail("\(outcomes)") }
    guard case .failed(.brokeRules, _, let broken) = outcomes[1] else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(broken?.lines.map(\.text), ["item 1: missing id"])
  }

  // MARK: - 結果の無い回

  /// 結果も申告も出さずに終えた agent の回は失敗——地の文の答えを黙って「何も無い」と読まない。
  func testAgentEndingWithoutAResultFails() throws {
    start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([]))

    jobs.finish(0, replied("報告することはありません。"))

    XCTAssertEqual(failed, #"the part "r" ended without giving a result"#)
  }

  /// 入力を読み切らないまま終えた回は、読み残しの失敗（読んだ位置は進まず、行は次の回に届く）。
  func testAgentEndingWithoutReadingItsInputFails() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a"), row("b")], reachesJudge: false))

    use(0, .readRunRows, ["limit": 1])
    XCTAssertTrue(use(0, .putRows, ["rows": [["id": "f:a"]]]).isError, "読み切るまで断る")
    jobs.finish(0, done())

    XCTAssertEqual(failed, #"the part "p" ended without reading 1 of its input item"#)
    XCTAssertNil(breach, "読み残しの断りは外れた件に数えない")
  }

  /// 断られた結果を直さず、結果の無いまま終えた回は出力の形式エラーの失敗——結果なし（道具を一度も呼ばなかった回）と分ける。
  func testRefusedResultsLeftUnfixedFailAsBrokenRules() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], reachesJudge: false))

    readAll(0)
    XCTAssertTrue(use(0, .putRows, ["rows": [["note": "id が無い"]]]).isError)
    jobs.finish(0, done())

    XCTAssertEqual(failed, #"the output of part "p" broke the rules: item 1: missing id"#)
    XCTAssertEqual(breach?.lines.map(\.text), ["item 1: missing id"])
  }

  /// 呼び出しの形の誤り（空の報告など）で断られたまま終えた回も出力の形式エラーの失敗——道具を呼んだ回を結果なしと言わない。
  func testACallOfTheWrongShapeLeftUnfixedFailsAsBrokenRules() throws {
    start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([]))

    XCTAssertTrue(use(0, .putReport, ["text": "  \n"]).isError)
    jobs.finish(0, done())

    XCTAssertEqual(failed, #"the output of part "r" broke the rules: the report is empty"#)
  }

  /// 結果を断られた後の「何も無い」は断る——断られた結果を「何も無い」で覆って成功にしない。
  func testNothingAfterARefusedResultIsRefusedAndTheRunFails() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], reachesJudge: false))

    readAll(0)
    XCTAssertTrue(use(0, .putRows, ["rows": [["note": "id が無い"]]]).isError)
    XCTAssertTrue(use(0, .reportNothing, ["why": "残す行が無い"]).isError)
    jobs.finish(0, done())

    XCTAssertEqual(failed, #"the output of part "p" broke the rules: item 1: missing id"#)
  }

  /// 断った結果の呼び出しは記録に残り、直して受けた回は成功——断りは同じ会話の中の直しで、別の呼び出しは起こさない。
  func testRefusedResultsAreRecordedAndTheFixedResultPasses() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], reachesJudge: false))

    readAll(0)
    XCTAssertTrue(use(0, .putRows, ["rows": [["note": "id が無い"]]]).isError)
    XCTAssertFalse(use(0, .putRows, ["rows": [["id": "f:a"]]]).isError)
    jobs.finish(0, done())

    XCTAssertEqual(jobs.calls.count, 1)
    XCTAssertEqual(
      succeeded,
      .process([
        AutomationPartRow(
          id: "f:a", text: #"{"id":"f:a"}"#, origin: origin("a"), source: row("a").source)
      ]), "\(outcomes)")
    XCTAssertEqual(breach?.lines.map(\.text), ["item 1: missing id"])
  }
}
