import XCTest

@testable import Orbe

/// 報告と仕事の文の残し方——前後の空白を除き、上限（2,000 字）を超えれば上限で切って「…」を付ける。agent は道具で出し、
/// 出し直せば後の報告で置き換え、空の文は断った結果に数えずに断る（何も無い回は report_nothing）。コマンドの報告は標準出力で、空なら報告なし。
///
/// 壊れると何が起きるか: 報告の前後の空行がボードの見出しと知らせの 1 行目を空にする。空の文が空の報告として残る。長い報告・
/// 長い応答が回の記録（部品ごとに 20 回）を丸ごと膨らませ、ボードの実行履歴が読めない長さになる。仕事が「何もしなかった」を
/// 言えない。
final class AutomationPartPassReportTests: AutomationPartPassTestCase {
  private static let long = String(repeating: "あ", count: 2_500)
  private static let cut = String(repeating: "あ", count: 2_000) + "…"

  /// 空の報告は断った結果に数えずに断り、出し直した報告は前の報告を置き換える（直した中身を受ける）。前後の空白を除き、長ければ
  /// 切る。
  func testReportIsTrimmedCutReplacedAndAnEmptyTextIsRefused() {
    for _ in 0..<2 {
      start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([row("a")]))
    }

    readAll(0)
    readAll(1)
    XCTAssertTrue(use(0, .putReport, ["text": "  \n"]).isError)
    XCTAssertFalse(use(0, .putReport, ["text": "下書き"]).isError)
    XCTAssertFalse(
      use(0, .putReport, ["text": "\n開いている PR は 2 件。\n- #1 …\n- #2 …\n\n"]).isError,
      "出し直しは受ける")
    use(1, .putReport, ["text": Self.long])
    jobs.finish(0, done())
    jobs.finish(1, done())

    XCTAssertEqual(
      outputs, [.report("開いている PR は 2 件。\n- #1 …\n- #2 …"), .report(Self.cut)], "\(outcomes)")
    XCTAssertNil(outcomes.first?.breach)
  }

  /// 受けた報告の後に文字列でない報告を断られ、直さずに終えた回は出力の形式エラーの失敗。
  func testARefusedReportAfterAnAcceptedOneMustBeFixed() {
    start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([row("a")]))

    readAll(0)
    use(0, .putReport, ["text": "報告"])
    XCTAssertTrue(use(0, .putReport, ["text": 1]).isError)
    jobs.finish(0, done())

    XCTAssertEqual(failed, #"the output of part "r" broke the rules: text has the wrong type"#)
  }

  /// 空の報告を断られた後も、何も無い回として申告できる（中身の無い呼び出しは断った結果に数えない）。
  func testAnEmptyReportStillLeavesRoomToReportNothing() {
    start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([]))

    XCTAssertTrue(use(0, .putReport, ["text": "  \n"]).isError)
    XCTAssertFalse(use(0, .reportNothing, ["why": "動きなし"]).isError)
    jobs.finish(0, done())

    XCTAssertEqual(outputs, [.report(nil)], "\(outcomes)")
  }

  func testNothingToReportLeavesNoText() {
    start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([]))
    start(AutomationGraphTests.command("r", from: ["f"], deliver: .report), .report, .report([]))

    use(0, .reportNothing, ["why": "動きなし"])
    jobs.finish(0, done())
    jobs.finish(1, printed("  \n"))

    XCTAssertEqual(outputs, [.report(nil), .report(nil)], "\(outcomes)")
  }

  func testWorkReportsWhatItDidOrWhyItDidNothing() {
    for _ in 0..<2 { start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work) }

    use(0, .putReport, ["text": Self.long])
    use(1, .reportNothing, ["why": "対象が無い"])
    jobs.finish(0, done())
    jobs.finish(1, done())

    XCTAssertEqual(
      outputs, [.work(.done(Self.cut)), .work(.nothing("対象が無い"))], "\(outcomes)")
  }
}
