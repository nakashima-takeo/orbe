import XCTest

@testable import Orbe

/// 出力先の agent の読み替え。出力先の段は題「agent」・解いたモデルの札・依頼文の全文・ツールの札。応答のある回だけが「出した」で、
/// 全文を折り返し、一覧の右端は「に完了」。応答の無い回は何も出さなかった回で「何もしなかった」。
///
/// 壊れると何が起きるか: 承認なしで裏で走る依頼文と名指しのツールを、ボードで確かめられない。agent が報告した 1 行目が
/// 見出しや知らせに出ない。応答の長い回で一覧の右端があふれる。何もしなかった回のたびに通知が鳴る。
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

  func testOnlyAnAgentRunWithAReplyIsProduced() throws {
    let summary = BoardAutomationSummary(DesignSceneFixtures.boardAgentExample(), text: text)
    XCTAssertEqual(summary.runs.map(\.tone), [.produced, .quiet, .failed, .produced])
    XCTAssertEqual(summary.runs.map(\.wraps), [true, false, true, true])
    XCTAssertTrue(summary.runs[0].result.hasPrefix("レビュー待ちの PR 2 件を #dev-me に投稿した。\n- #412"))
    XCTAssertEqual(summary.runs[1].result, "何もしなかった")
    XCTAssertEqual(
      summary.runs[2].result,
      "失敗：the sink agent reported an error: mcp__slack__slack_send_message was refused")
    XCTAssertEqual(summary.mark, "9:00 に完了", "応答があっても右端は「完了」")
    XCTAssertEqual(summary.last, "前回 今日 9:00　レビュー待ちの PR 2 件を #dev-me に投稿した。")
    XCTAssertEqual(summary.latestLine, "レビュー待ちの PR 2 件を #dev-me に投稿した。")
  }

  /// 応答のあった回の出力先の件数は 1、応答の無かった回は 0。成功して出力先の記録が無い回（agent を起こさなかった回）は出した回に
  /// 数えない。
  func testTheOutputCountIsOneOnlyForARunWithAReply() throws {
    var automation = DesignSceneFixtures.boardAgentExample()
    XCTAssertEqual(BoardAutomationSummary(automation, text: text).nodes.last?.count, 1)

    automation.runs[0].sink = .agent(
      AutomationAgentReport(commandLine: "claude -p --model sonnet", ending: "exited 0", text: nil))
    let quiet = BoardAutomationSummary(automation, text: text)
    XCTAssertEqual(quiet.nodes.last?.count, 0)
    XCTAssertEqual(quiet.mark, "9:00 に何もしなかった")

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
