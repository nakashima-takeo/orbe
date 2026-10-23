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

  /// コマンドの失敗は 0 以外の終了コード——標準出力に項目があっても使わない。
  func testCommandFailsByItsExitCode() throws {
    start(AutomationGraphTests.fetch("f"), .fetch, .fetch(since: nil))

    jobs.finish(0, printed(fetchedLines(["a"]), exit: 2, stderr: "down"))

    guard case .failed(.ended, _, _) = outcomes.first else { return XCTFail("\(outcomes)") }
    XCTAssertTrue(try XCTUnwrap(failed).contains("down"))
  }

  private func fetchedLines(_ ids: [String]) -> String {
    ids.map {
      #"{"id":"\#($0)","link":"https://example.com/\#($0)","body":"\#($0)","time":"2026-10-10T09:00:00Z"}"#
    }.joined(separator: "\n")
  }

  /// 受けた結果の後に断られた呼び出しがあり、直さずに終えた回は出力の形式エラーの失敗——受けた分だけで成功にすると、断られた
  /// 呼び出しの中身が黙って消える。直して受ければ成功。
  func testARefusedCallAfterAcceptedResultsMustBeFixed() throws {
    for _ in 0..<2 {
      start(
        AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
        .process([row("a"), row("b")], reachesJudge: false))
    }
    for index in 0..<2 {
      readAll(index)
      XCTAssertFalse(use(index, .putRows, ["rows": [["id": "f:a"]]]).isError)
      XCTAssertTrue(use(index, .putRows, ["rows": [["note": "b"]]]).isError)
    }
    XCTAssertFalse(use(1, .putRows, ["rows": [["id": "f:b"]]]).isError)
    jobs.finish(0, done())
    jobs.finish(1, done())

    guard case .failed(.brokeRules, _, let unfixed) = outcomes.first else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(unfixed?.lines.map(\.text), ["item 1: missing id"])
    guard case .succeeded(.process(let rows), _, let fixed) = outcomes.last else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(rows.map(\.id), ["f:a", "f:b"])
    XCTAssertEqual(fixed?.lines.map(\.text), ["item 1: missing id"])
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

  /// 呼び出しの形の誤り（配列でない引数など）で断られたまま終えた回も出力の形式エラーの失敗——道具を呼んだ回を結果なしと
  /// 言わない。
  func testACallOfTheWrongShapeLeftUnfixedFailsAsBrokenRules() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], reachesJudge: false))

    readAll(0)
    XCTAssertTrue(use(0, .putRows, ["rows": "f:a"]).isError)
    jobs.finish(0, done())

    XCTAssertEqual(failed, #"the output of part "p" broke the rules: rows must be an array"#)
  }

  /// 何も無いと申告した後の結果の呼び出しは外れた呼び出しとして断り、そのまま終えた回は出力の形式エラーの失敗——結果を黙って
  /// 捨てて 0 件の成功（今の集合なら今有効な項目の一斉の無効化）にしない。
  func testAResultAfterReportingNothingFailsTheRun() throws {
    start(
      AutomationGraphTests.agent(
        "f", tools: ["mcp__slack__search"], deliver: .nextPart, coverage: .currentSet),
      .fetch, .fetch(since: nil))

    XCTAssertFalse(use(0, .reportNothing, ["why": "無い"]).isError)
    XCTAssertTrue(
      use(
        0, .putItems,
        [
          "items": [
            ["id": "a", "link": "https://e.com/a", "body": "a", "time": "2026-10-10T09:00:00Z"]
          ]
        ]
      ).isError)
    jobs.finish(0, done())

    XCTAssertEqual(
      failed, #"the output of part "f" broke the rules: a result after report_nothing"#)
  }

  /// 断られたまま終えた回の記録は、断られたままの件を先に並べる（先に直した件ではなく）。数は回全体。
  func testABrokenRunRecordsTheUnfixedItemsFirst() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a")], reachesJudge: false))

    readAll(0)
    use(0, .putRows, ["rows": [["note": "1"], ["note": "2"]]])
    use(0, .putRows, ["rows": [["id": "f:a"]]])
    use(0, .putRows, ["rows": [["id": "f:a"]]])
    jobs.finish(0, done())

    XCTAssertEqual(breach?.count, 3)
    XCTAssertEqual(
      breach?.lines.map(\.text),
      ["item 1: id f:a appeared twice", "item 1: missing id", "item 2: missing id"])
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
