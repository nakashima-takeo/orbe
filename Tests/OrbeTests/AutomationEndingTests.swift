import XCTest

@testable import Orbe

/// 回の記録の終わり方——走らせ役の終わり方から写した種類が、AI の読む英文を一字一句変えないこと。
///
/// 壊れると何が起きるか: `list_automations`・試走・知らせで AI が読む終わり方の英文が黙って変わるか、別の終わり方を言う。
/// 写し間違えた種類は画面の日本語も別の終わり方にする（制限時間で止めたのに「出力が多すぎて止めた」と出る）。
final class AutomationEndingTests: OrbeTestCase {
  /// どの終わり方も、写した種類の英文は走らせ役の終わり方の英文と同じ。
  func testTheEndingSaysWhatTheRunnersEndingSays() {
    let endings: [BackgroundEnding] =
      [.exited(1), .signaled(9), .stopped]
      + BackgroundProcess.Limit.allCases.map(BackgroundEnding.limited)
      + [
        .notStarted(.agentNotFound("claude")), .notStarted(.directoryMissing("~/work/scripts")),
        .notStarted(.launchFailed(2)),
        .toolsUnavailable(["mcp__slack__search", "mcp__gmail__read"]),
      ]

    for ending in endings {
      XCTAssertEqual(AutomationEnding(ending).text, ending.text, "\(ending)")
    }
  }
}
