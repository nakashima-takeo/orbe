import XCTest

@testable import Orbe

/// 報告と通知の読み替え。報告のある回は「出した」で全文を折り返し、報告の無い回は「報告なし」（「すべて除外」と読まない）。通知は
/// 通知先の言葉で、どの出力先でも出力先の段の注記のいちばん下に出る。
///
/// 壊れると何が起きるか: 言うことが無かった回が「処理 1 ですべて除外」と読め、指示文の誤りと取り違える。報告が 1 行で省かれ、
/// ボードで読めなくなる。ピルと押した先の行が別の文になる。
extension BoardAutomationSummaryTests {
  func testAReportRunIsProducedAndWrapsTheWholeText() throws {
    let summary = BoardAutomationSummary(DesignSceneFixtures.boardReportExample(), text: text)
    XCTAssertEqual(summary.output, "報告")
    XCTAssertEqual(summary.runs.map(\.tone), [.produced, .produced, .quiet, .failed, .produced])
    XCTAssertEqual(summary.runs.map(\.wraps), [true, true, false, true, true])
    XCTAssertEqual(summary.runs[2].result, "報告なし")
    XCTAssertTrue(summary.runs[0].result.hasPrefix("開いている PR は 3 件。"))
    XCTAssertTrue(summary.runs[0].result.contains("\n- #416"), "全文を残す")
    XCTAssertEqual(summary.mark, "10/3 18:00 に報告")
    XCTAssertEqual(summary.last, "前回 10/3 18:00　開いている PR は 3 件。うち 1 件はレビュー待ちが 2 日を超えている。")
    XCTAssertEqual(summary.latestLine, "開いている PR は 3 件。うち 1 件はレビュー待ちが 2 日を超えている。")

    let output = try XCTUnwrap(summary.nodes.last)
    XCTAssertEqual(output.title, "報告")
    XCTAssertNil(output.means)
    XCTAssertNil(output.source)
    XCTAssertEqual(output.notes, ["通知：メニューバー"])
    XCTAssertEqual(output.count, 1)
  }

  func testNotifyIsTheLastNoteOfAnySink() throws {
    let summary = BoardAutomationSummary(
      DesignSceneFixtures.boardStepsNotifyExample(), text: text)
    XCTAssertEqual(
      summary.nodes.last?.notes, ["これまでに採用 9件 / 見送り 3件", "通知：メニューバー"])
    let center = BoardAutomationSummary(
      DesignSceneFixtures.boardReportNotificationCenterExample(), text: text)
    XCTAssertEqual(center.nodes.last?.notes, ["通知：通知センター"])
  }

  func testTheLatestLineOfAFailureIsItsFirstLine() throws {
    var automation = DesignSceneFixtures.boardReportExample()
    automation.runs.insert(
      AutomationRun(
        startedAt: DesignSceneFixtures.automationAt(14),
        endedAt: DesignSceneFixtures.automationAt(14),
        trigger: .now, source: nil, fresh: nil, steps: [], sink: nil,
        failure: "the fetch ended: exited 1: line one\nline two"),
      at: 0)
    let summary = BoardAutomationSummary(automation, text: text)
    XCTAssertEqual(summary.latestLine, "失敗：the fetch ended: exited 1: line one")
  }
}
