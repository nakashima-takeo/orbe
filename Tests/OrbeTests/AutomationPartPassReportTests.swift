import XCTest

@testable import Orbe

/// 報告と仕事の文の残し方——前後の空白を除き、上限（2,000 字）を超えれば上限で切って「…」を付ける。agent は道具で 1 度だけ
/// 出し、空の文は断る（何も無い回は report_nothing）。コマンドの報告は標準出力で、空なら報告なし。
///
/// 壊れると何が起きるか: 報告の前後の空行がボードの見出しと知らせの 1 行目を空にする。空の文が空の報告として残る。長い報告・
/// 長い応答が回の記録（部品ごとに 20 回）を丸ごと膨らませ、ボードの実行履歴が読めない長さになる。仕事が「何もしなかった」を
/// 言えない。
final class AutomationPartPassReportTests: AutomationPartPassTestCase {
  private static let long = String(repeating: "あ", count: 2_500)
  private static let cut = String(repeating: "あ", count: 2_000) + "…"

  func testReportIsTrimmedCutAndAnEmptyTextIsRefused() {
    for _ in 0..<2 {
      start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([row("a")]))
    }

    readAll(0)
    readAll(1)
    XCTAssertTrue(use(0, .putReport, ["text": "  \n"]).isError)
    use(0, .putReport, ["text": "\n開いている PR は 2 件。\n- #1 …\n- #2 …\n\n"])
    XCTAssertTrue(use(0, .putReport, ["text": "2 つ目"]).isError, "報告は 1 度")
    use(1, .putReport, ["text": Self.long])
    jobs.finish(0, done())
    jobs.finish(1, done())

    XCTAssertEqual(
      outputs, [.report("開いている PR は 2 件。\n- #1 …\n- #2 …"), .report(Self.cut)], "\(outcomes)")
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
