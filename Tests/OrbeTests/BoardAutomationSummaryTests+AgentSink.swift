import XCTest

@testable import Orbe

/// 出力先の agent の読み替え。出力先の段は題「agent」・解いたモデルの札・依頼文の全文・ツールの札。することが無いと申告した回
/// だけが何も出さなかった回で「何もしなかった：理由」（見出しと一覧の右端は「何もしなかった」）。ほかの起こした回は「出した」で、
/// 応答があれば全文を折り返し、無ければ「完了」。一覧の右端は「に完了」。
///
/// 壊れると何が起きるか: 承認なしで裏で走る依頼文と名指しのツールを、ボードで確かめられない。agent が報告した 1 行目が
/// 見出しや知らせに出ない。応答の長い回で一覧の右端があふれる。することが無かった回のたびに通知が鳴る。空の応答で終えた回
/// （書き込んだ後に黙った回も）を何もしなかった回と言い切り、調べる理由を消す。
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

  func testOnlyAnAgentRunThatSaidNothingToDoIsQuiet() throws {
    let summary = BoardAutomationSummary(DesignSceneFixtures.boardAgentExample(), text: text)
    XCTAssertEqual(summary.runs.map(\.tone), [.produced, .quiet, .failed, .produced])
    XCTAssertEqual(summary.runs.map(\.wraps), [true, true, true, false])
    XCTAssertTrue(summary.runs[0].result.hasPrefix("レビュー待ちの PR 2 件を #dev-me に投稿した。\n- #412"))
    XCTAssertEqual(summary.runs[1].result, "何もしなかった：レビュー待ちの PR は無かった")
    XCTAssertEqual(summary.runs[3].result, "完了", "空の応答は何もしなかったと言い切らない")
    XCTAssertEqual(
      summary.runs[2].result,
      "失敗：the sink agent reported an error: mcp__slack__slack_send_message was refused")
    XCTAssertEqual(summary.mark, "9:00 に完了", "応答があっても右端は「完了」")
    XCTAssertEqual(summary.last, "前回 今日 9:00　レビュー待ちの PR 2 件を #dev-me に投稿した。")
    XCTAssertEqual(summary.latestLine, "レビュー待ちの PR 2 件を #dev-me に投稿した。")
  }

  /// することが無いと申告した回の出力先の件数は 0、ほかの起こした回は 1（空の応答でも）。成功して出力先の記録が無い回（agent を
  /// 起こさなかった回）は出した回に数えない。
  func testTheOutputCountIsZeroOnlyForARunThatSaidNothingToDo() throws {
    var automation = DesignSceneFixtures.boardAgentExample()
    XCTAssertEqual(BoardAutomationSummary(automation, text: text).nodes.last?.count, 1)

    automation.runs[0].sink = .agent(
      AutomationAgentReport(commandLine: "claude -p --model sonnet", ending: "exited 0", text: nil))
    let done = BoardAutomationSummary(automation, text: text)
    XCTAssertEqual(done.nodes.last?.count, 1)
    XCTAssertEqual(done.mark, "9:00 に完了")
    XCTAssertEqual(done.latestLine, "完了")

    automation.runs[0].sink = .agent(
      AutomationAgentReport(
        commandLine: "claude -p --model sonnet", ending: "exited 0", text: nil, nothing: "無い"))
    let quiet = BoardAutomationSummary(automation, text: text)
    XCTAssertEqual(quiet.nodes.last?.count, 0)
    XCTAssertEqual(quiet.mark, "9:00 に何もしなかった")
    XCTAssertEqual(quiet.last, "前回 今日 9:00　何もしなかった")

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
