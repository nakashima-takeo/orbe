import XCTest

@testable import orbe_report

/// hook payload からの文言抽出（`agentMessage` / `truncateMessage`）の契約を固定する。
/// フィールド形は実 payload 採取（2026-07・claude / codex 実機）に基づく:
/// - claude Notification: `{"message": "Claude needs your permission", "notification_type": ...}`
/// - claude PreToolUse(AskUserQuestion): `{"tool_input": {"questions": [{"question": ..., ...}]}}`
/// - claude / codex Stop: `{"last_assistant_message": "...", "stop_hook_active": false, ...}`
final class MessageExtractTests: XCTestCase {
  // MARK: waiting

  /// Notification の message を waiting の文言に使う。
  func testWaitingUsesNotificationMessage() {
    let obj: [String: Any] = [
      "hook_event_name": "Notification",
      "message": "Claude needs your permission",
      "notification_type": "permission_prompt",
    ]
    XCTAssertEqual(agentMessage(state: "waiting", stdin: obj), "Claude needs your permission")
  }

  /// message が無ければ AskUserQuestion の先頭の質問文へフォールバックする。
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
    XCTAssertEqual(agentMessage(state: "waiting", stdin: obj), "AとBどちらにしますか？")
  }

  /// message（空でない）が質問文より優先される。
  func testWaitingPrefersMessageOverQuestions() {
    let obj: [String: Any] = [
      "message": "notify",
      "tool_input": ["questions": [["question": "q"]]],
    ]
    XCTAssertEqual(agentMessage(state: "waiting", stdin: obj), "notify")
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

  /// Stop payload の last_assistant_message を done の文言に使う（claude / codex 共通のフィールド名）。
  func testDoneUsesLastAssistantMessage() {
    let obj: [String: Any] = [
      "hook_event_name": "Stop",
      "stop_hook_active": false,
      "last_assistant_message": "PR #142 を作成しました",
      "background_tasks": [[String: Any]](),
    ]
    XCTAssertEqual(agentMessage(state: "done", stdin: obj), "PR #142 を作成しました")
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

  /// 1000 文字で切る（制御ソケット 1 行上限への防御。表示は 3 行 clamp なので切っても足りる）。
  func testTruncateCapsAt1000Characters() {
    let long = String(repeating: "あ", count: 1500)
    XCTAssertEqual(truncateMessage(long)?.count, 1000)
    XCTAssertEqual(truncateMessage(String(repeating: "x", count: 1000))?.count, 1000)
  }

  /// waiting/done 経路でも truncate が効く（空 message は質問文へフォールバック）。
  func testExtractionAppliesTruncation() {
    let obj: [String: Any] = [
      "message": "   ",
      "tool_input": ["questions": [["question": "  q  "]]],
    ]
    XCTAssertEqual(agentMessage(state: "waiting", stdin: obj), "q")
  }
}
