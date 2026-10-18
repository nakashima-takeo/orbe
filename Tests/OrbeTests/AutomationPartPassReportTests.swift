import XCTest

@testable import Orbe

/// 報告と仕事の文の残し方——前後の空白を除き、空なら文無し、上限（2,000 字）を超えれば上限で切って「…」を付ける。
///
/// 壊れると何が起きるか: 報告の前後の空行がボードの見出しと知らせの 1 行目を空にする。空の応答が空の報告として残る。長い報告・
/// 長い応答が回の記録（部品ごとに 20 回）を丸ごと膨らませ、ボードの実行履歴が読めない長さになる。
final class AutomationPartPassReportTests: AutomationPartPassTestCase {
  private static let long = String(repeating: "あ", count: 2_500)
  private static let cut = String(repeating: "あ", count: 2_000) + "…"

  func testReportIsTrimmedAndAnEmptyOutputLeavesNoText() {
    for _ in 0..<2 {
      start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([row("a")]))
    }

    jobs.finish(0, replied("\n開いている PR は 2 件。\n- #1 …\n- #2 …\n\n"))
    jobs.finish(1, replied("  \n"))

    XCTAssertEqual(
      outputs, [.report("開いている PR は 2 件。\n- #1 …\n- #2 …"), .report(nil)], "\(outcomes)")
  }

  func testALongReportIsCut() {
    start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([row("a")]))

    jobs.finish(0, replied(Self.long))

    XCTAssertEqual(outputs, [.report(Self.cut)], "\(outcomes)")
  }

  func testAnEmptyWorkReplyIsDoneWithoutTextAndALongReplyIsCut() {
    for _ in 0..<2 { start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work) }

    jobs.finish(0, replied("  \n"))
    jobs.finish(1, replied(Self.long))

    XCTAssertEqual(outputs, [.work(.done(nil)), .work(.done(Self.cut))], "\(outcomes)")
  }
}
