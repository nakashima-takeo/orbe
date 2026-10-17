import XCTest

@testable import Orbe

/// 何も無い回——取得と判定の依頼文は nothing の 1 行だけを出させ、読みは nothing の 1 行だけ・何も出さない出力を正しい 0 件と
/// して受け、nothing の前の地の文と、項目と一緒の nothing の行は外れた行にする（処理は `AutomationPartPassTests`）。報告と仕事は
/// 最後の空でない行が nothing なら、前置きの文ごと報告の文にしない。
///
/// 壊れると何が起きるか: 何も無い回に黙ったモデルが催促されて地の文を返し、候補の無いよくある回に出し直しと通知が起きる。
/// nothing の前の地の文や項目と一緒の申告を黙って捨て、出力の誤りに気づけない。言うことの無い報告・何もしなかった仕事の
/// nothing の 1 行が、報告の文としてボードと通知にそのまま出る。
final class AutomationPartPassEmptyTests: AutomationPartPassTestCase {
  private static let nothing = #"{"nothing":"新しい項目が無い"}"#

  private func fetchAgent() -> AutomationPart {
    AutomationGraphTests.agent("f", tools: [Self.tool], deliver: .nextPart, coverage: .currentSet)
  }

  func testFetchAndJudgePromptsAskForANothingLine() throws {
    start(fetchAgent(), .fetch(.currentSet), .fetch(since: nil, lastOutput: []))
    start(
      AutomationGraphTests.agent("j", from: ["f"], deliver: .taskCandidates), .judge,
      judgeInput(["a"]))

    for index in 0..<2 {
      XCTAssertTrue(
        try XCTUnwrap(agentCall(index)).prompt.contains(
          #"output only this one line instead: {"nothing": "<why>"}"#),
        "\(index)")
    }
  }

  func testFetchOutputOfOnlyANothingLinePassesNoItems() throws {
    start(fetchAgent(), .fetch(.currentSet), .fetch(since: nil, lastOutput: ["a"]))

    jobs.finish(0, replied(Self.nothing))

    XCTAssertEqual(succeeded, .fetch(rows: [], lastOutput: []), "\(outcomes)")
    XCTAssertNil(breach)
  }

  func testJudgeOutputOfOnlyANothingLineProposesNothing() throws {
    start(
      AutomationGraphTests.agent("j", from: ["f"], deliver: .taskCandidates), .judge,
      judgeInput(["a"]))

    jobs.finish(0, replied(Self.nothing))

    XCTAssertEqual(succeeded, .judge(proposals: [], resolved: []), "\(outcomes)")
    XCTAssertNil(breach)
  }

  /// nothing の前の地の文は外れた行——依頼文は地の文を出さないよう言っている。申告の行そのものは外れた行にしない。
  func testProseBeforeANothingLineInAJudgeBreaksTheRules() throws {
    start(
      AutomationGraphTests.command("j", from: ["f"], deliver: .taskCandidates), .judge,
      judgeInput(["a"]))

    jobs.finish(0, printed("どれもタスクにしなくてよさそうです。\n" + Self.nothing))

    XCTAssertEqual(breach?.lines.map(\.line), [1], "\(outcomes)")
    XCTAssertNotNil(failed)
  }

  /// 項目と一緒に出た nothing の行は外れた行で、行番号は元の出力のまま。
  func testNothingLineAlongsideFetchedItemsBreaksTheRules() throws {
    start(
      AutomationGraphTests.fetch("f"), .fetch(.currentSet), .fetch(since: nil, lastOutput: []))

    let item =
      #"{"id":"a","link":"https://example.com/a","body":"a","time":"2026-10-10T09:00:00Z"}"#
    jobs.finish(0, printed(item + "\n\n" + Self.nothing))

    XCTAssertEqual(breach?.lines.map(\.line), [3], "\(outcomes)")
    XCTAssertNotNil(failed)
  }

  func testReportKeepsItsTextButNotANothingLine() {
    start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([row("a")]))
    start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([row("a")]))

    jobs.finish(0, replied("開いている PR は 2 件。\n"))
    jobs.finish(1, replied("障害はありません。\n" + Self.nothing))

    XCTAssertEqual(
      outputs, [.report("開いている PR は 2 件。"), .report(nil)], "\(outcomes)")
  }

  func testWorkKeepsItsTextButANothingLineIsTheReasonItDidNothing() {
    start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work)
    start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work)

    jobs.finish(0, replied("2 件を投稿した。\n"))
    jobs.finish(1, replied("今日は土曜日です。\n\n" + #"{"nothing":"土曜なので投稿しない"}"#))

    XCTAssertEqual(
      outputs, [.work(.done("2 件を投稿した。")), .work(.nothing("土曜なので投稿しない"))],
      "\(outcomes)")
  }
}
