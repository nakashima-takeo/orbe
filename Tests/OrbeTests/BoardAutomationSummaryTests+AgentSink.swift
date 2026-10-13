import XCTest

@testable import Orbe

/// 出力先の agent の読み替え。出力先の段は題「agent」・解いたモデルの札・依頼文の全文・ツールの札。起こした回は「出した」で、
/// 応答があれば全文を折り返し、無ければ「完了」。一覧の右端は応答の有無によらず「に完了」。
///
/// 壊れると何が起きるか: 承認なしで裏で走る依頼文と名指しのツールを、ボードで確かめられない。agent が報告した 1 行目が
/// 見出しや知らせに出ない。応答の長い回で一覧の右端があふれる。
extension BoardAutomationSummaryTests {
  func testAnAgentSinkShowsItsModelRequestAndTools() throws {
    let summary = BoardAutomationSummary(DesignSceneFixtures.boardAgentExample(), text: text)
    XCTAssertEqual(summary.output, "agent")
    XCTAssertFalse(summary.counted, "取得元が無ければ件数を持たない")
    let output = try XCTUnwrap(summary.nodes.last)
    XCTAssertEqual(output.role, .output)
    XCTAssertEqual(output.title, "agent")
    XCTAssertEqual(output.means, .model("sonnet"), "省略したモデルは解いて出す")
    XCTAssertEqual(
      output.verbatim, "自分がレビュー待ちの open な PR を gh で調べてまとめ、Slack の #dev-me に投稿して。土日なら何もしない。")
    XCTAssertEqual(output.tools, ["Bash(gh search prs:*)", "mcp__slack__slack_send_message"])
    XCTAssertEqual(output.notes, ["通知：メニューバー"])
    XCTAssertEqual(summary.nodes.map(\.role), [.trigger, .output])
  }

  func testAnAgentRunIsProducedAndWrapsItsReply() throws {
    let summary = BoardAutomationSummary(DesignSceneFixtures.boardAgentExample(), text: text)
    XCTAssertEqual(summary.runs.map(\.tone), [.produced, .produced, .failed, .produced])
    XCTAssertEqual(summary.runs.map(\.wraps), [true, false, true, true])
    XCTAssertTrue(summary.runs[0].result.hasPrefix("レビュー待ちの PR 2 件を #dev-me に投稿した。\n- #412"))
    XCTAssertEqual(summary.runs[1].result, "完了")
    XCTAssertEqual(
      summary.runs[2].result,
      "失敗：the sink agent reported an error: mcp__slack__slack_send_message was refused")
    XCTAssertEqual(summary.mark, "9:00 に完了", "応答があっても右端は「完了」")
    XCTAssertEqual(summary.last, "前回 今日 9:00　レビュー待ちの PR 2 件を #dev-me に投稿した。")
    XCTAssertEqual(summary.latestLine, "レビュー待ちの PR 2 件を #dev-me に投稿した。")
  }

  /// 起こした回の出力先の件数は 1。取得元があって新着の無い回は agent へ届いていない。
  func testTheOutputCountIsOneForARunThatStartedTheAgent() throws {
    var automation = DesignSceneFixtures.boardAgentExample()
    XCTAssertEqual(BoardAutomationSummary(automation, text: text).nodes.last?.count, 1)

    automation.runs.insert(
      AutomationRun(
        startedAt: DesignSceneFixtures.automationAt(9),
        endedAt: DesignSceneFixtures.automationAt(9),
        trigger: .now, source: nil, fresh: nil, steps: [], lastStepCountedBySink: false, sink: nil,
        failure: nil),
      at: 0)
    XCTAssertEqual(BoardAutomationSummary.tone(automation.runs[0]), .quiet, "起こさなかった回")
  }
}
