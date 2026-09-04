import XCTest

@testable import orbe_report

/// hook payload からの文言抽出（`agentMessage` / `truncateMessage`）の契約を固定する。
/// 出所（`source`）は**どのフィールドから取ったか**そのもので、Orbe 側の上書き可否
/// （ツール由来を通知由来から守る）が依る唯一の軸。語（`"tool"` / `"notification"`）は
/// モジュールを跨ぐ文字列契約なので、ここと Orbe 側の両方で固定する。
/// フィールド形は実 payload 採取（2026-07・claude / codex 実機）に基づく:
/// - claude Notification: `{"message": "Claude needs your permission", "notification_type": ...}`
/// - claude PreToolUse(AskUserQuestion): `{"tool_input": {"questions": [{"question": ..., ...}]}}`
/// - claude PreToolUse(ExitPlanMode): `{"tool_input": {"plan": "..."}}`（questions を持たない）
/// - claude / codex Stop: `{"last_assistant_message": "...", "stop_hook_active": false, ...}`
final class MessageExtractTests: XCTestCase {
  // MARK: waiting

  /// Notification の message を waiting の文言に使う（出所は通知）。
  func testWaitingUsesNotificationMessage() {
    let obj: [String: Any] = [
      "hook_event_name": "Notification",
      "message": "Claude needs your permission",
      "notification_type": "permission_prompt",
    ]
    XCTAssertEqual(agentMessage(state: "waiting", stdin: obj)?.text, "Claude needs your permission")
    XCTAssertEqual(agentMessage(state: "waiting", stdin: obj)?.source, "notification")
  }

  /// message が無ければ AskUserQuestion の先頭の質問文へフォールバックする（出所はツール）。
  func testWaitingFallsBackToFirstQuestion() {
    let obj: [String: Any] = [
      "hook_event_name": "PreToolUse",
      "tool_name": "AskUserQuestion",
      "tool_input": [
        "questions": [
          ["question": "AとBどちらにしますか？", "header": "選択", "options": [["label": "A"]]],
          ["question": "2 問目は使わない"],
        ]
      ],
    ]
    XCTAssertEqual(agentMessage(state: "waiting", stdin: obj)?.text, "AとBどちらにしますか？")
    XCTAssertEqual(agentMessage(state: "waiting", stdin: obj)?.source, "tool")
  }

  /// ExitPlanMode の待ちは質問文を持たないので文言なし（計画本文は載せない）。
  func testWaitingForExitPlanModeHasNoMessage() {
    let obj: [String: Any] = [
      "hook_event_name": "PreToolUse",
      "tool_name": "ExitPlanMode",
      "tool_input": ["plan": "1. まず調べる\n2. 次に直す"],
    ]
    XCTAssertNil(agentMessage(state: "waiting", stdin: obj))
  }

  /// message（空でない）が質問文より優先され、出所も通知になる。
  func testWaitingPrefersMessageOverQuestions() {
    let obj: [String: Any] = [
      "message": "notify",
      "tool_input": ["questions": [["question": "q"]]],
    ]
    XCTAssertEqual(agentMessage(state: "waiting", stdin: obj)?.text, "notify")
    XCTAssertEqual(agentMessage(state: "waiting", stdin: obj)?.source, "notification")
  }

  /// どちらも無い waiting（codex PermissionRequest 等）は nil＝文言なし。
  func testWaitingWithoutKnownFieldsIsNil() {
    XCTAssertNil(agentMessage(state: "waiting", stdin: ["tool_name": "Bash"]))
    XCTAssertNil(agentMessage(state: "waiting", stdin: nil))
  }

  /// questions の構造崩れ（配列でない・question 欠落）は nil に落ちる。
  func testWaitingMalformedQuestionsIsNil() {
    XCTAssertNil(agentMessage(state: "waiting", stdin: ["tool_input": ["questions": "x"]]))
    XCTAssertNil(
      agentMessage(state: "waiting", stdin: ["tool_input": ["questions": [[String: Any]()]]]))
  }

  // MARK: done

  /// Stop payload の last_assistant_message を done の文言に使う（claude / codex 共通のフィールド名。
  /// エージェント自身が語った応答なので出所はツール）。
  func testDoneUsesLastAssistantMessage() {
    let obj: [String: Any] = [
      "hook_event_name": "Stop",
      "stop_hook_active": false,
      "last_assistant_message": "PR #142 を作成しました",
      "background_tasks": [[String: Any]](),
    ]
    XCTAssertEqual(agentMessage(state: "done", stdin: obj)?.text, "PR #142 を作成しました")
    XCTAssertEqual(agentMessage(state: "done", stdin: obj)?.source, "tool")
  }

  /// last_assistant_message を持たない Stop（agy 等）は nil＝文言なしで乱れない。
  func testDoneWithoutLastAssistantMessageIsNil() {
    XCTAssertNil(agentMessage(state: "done", stdin: ["session_id": "s1"]))
    XCTAssertNil(agentMessage(state: "done", stdin: nil))
  }

  // MARK: それ以外の状態

  /// working（done→working 読み替え後を含む）・idle・clear は文言を持たない。
  func testOtherStatesHaveNoMessage() {
    let obj: [String: Any] = ["message": "m", "last_assistant_message": "l"]
    XCTAssertNil(agentMessage(state: "working", stdin: obj))
    XCTAssertNil(agentMessage(state: "idle", stdin: obj))
    XCTAssertNil(agentMessage(state: "clear", stdin: obj))
  }

  // MARK: truncateMessage

  /// trim して空なら nil。
  func testTruncateEmptyToNil() {
    XCTAssertNil(truncateMessage(nil))
    XCTAssertNil(truncateMessage(""))
    XCTAssertNil(truncateMessage("  \n\t "))
  }

  /// 前後の空白・改行は落とし、中身は保つ。
  func testTruncateTrims() {
    XCTAssertEqual(truncateMessage("  hello \n"), "hello")
  }

  /// C0 制御文字（改行・タブ以外）は落とす——文言は `orb agent prompt` の stdout として操作者の
  /// 端末へ生で流れるので、ESC 列や `\r` が端末に解釈される形（行の上書き・OSC）を入口で断つ。
  func testTruncateDropsC0ControlCharactersExceptNewlineAndTab() {
    XCTAssertEqual(
      truncateMessage("ok\u{1B}[1A\u{1B}[2K\rdone\n\ttab\u{07}\u{00}"), "ok[1A[2Kdone\n\ttab")
    XCTAssertNil(truncateMessage("\u{1B}\u{1B}"), "制御文字だけの文言は空扱い")
  }

  /// 1000 文字で切る（制御ソケット 1 行上限への防御。表示は 3 行 clamp なので切っても足りる）。
  func testTruncateCapsAt1000Characters() {
    let long = String(repeating: "あ", count: 1500)
    XCTAssertEqual(truncateMessage(long)?.count, 1000)
    XCTAssertEqual(truncateMessage(String(repeating: "x", count: 1000))?.count, 1000)
  }

  /// waiting/done 経路でも truncate が効く（空 message は質問文へフォールバック）。
  /// 出所はフォールバック先に従ってツール——文言と出所がずれない。
  func testExtractionAppliesTruncation() {
    let obj: [String: Any] = [
      "message": "   ",
      "tool_input": ["questions": [["question": "  q  "]]],
    ]
    XCTAssertEqual(agentMessage(state: "waiting", stdin: obj)?.text, "q")
    XCTAssertEqual(agentMessage(state: "waiting", stdin: obj)?.source, "tool")
  }
}
