import XCTest

@testable import Orbe

/// 回の記録の終わり方——走らせ役の終わり方から写した種類が、AI の読む英文を一字一句変えないこと。
///
/// 壊れると何が起きるか: `list_automations`・試走・知らせで AI が読む終わり方の英文が黙って変わるか、別の終わり方を言う。
/// 写し間違えた種類は画面の日本語も別の終わり方にする（制限時間で止めたのに「出力が多すぎて止めた」と出る）。
final class AutomationEndingTests: OrbeTestCase {
  /// どの終わり方も、写した種類がその終わり方の英文を言う。
  func testTheEndingSaysWhatTheRunnerEndedWith() {
    let endings: [(BackgroundEnding, String)] = [
      (.exited(1), "exited 1"),
      (.signaled(9), "killed by signal 9"),
      (.stopped, "stopped"),
      (.limited(.elapsed), "stopped at the time limit"),
      (.limited(.idle), "stopped after producing no output for too long"),
      (.limited(.output), "stopped at the output limit"),
      (.notStarted(.agentNotFound("claude")), "not started (claude is not installed)"),
      (
        .notStarted(.directoryMissing("~/work/scripts")),
        "not started (directory missing: ~/work/scripts)"
      ),
      (.notStarted(.launchFailed(2)), "not started (launch failed: No such file or directory)"),
      (
        .toolsUnavailable(["mcp__slack__search", "mcp__gmail__read"]),
        "tools unavailable: mcp__slack__search, mcp__gmail__read"
      ),
    ]

    for (ending, text) in endings {
      XCTAssertEqual(AutomationEnding(ending).text, text, "\(ending)")
    }
  }
}
