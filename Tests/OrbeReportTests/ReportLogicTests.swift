import XCTest

@testable import orbe_report

/// orbe-report の stdin JSON 解釈（ReportLogic）の契約を固定する。
/// claude はバックグラウンド作業を残してターンを終えられるため、Stop hook の
/// `background_tasks` に running があれば done を working に読み替える。
final class ReportLogicTests: XCTestCase {
  // MARK: effectiveState

  /// done + running な bg Bash → working。
  func testDoneWithRunningShellTaskBecomesWorking() {
    let obj: [String: Any] = [
      "session_id": "s1",
      "background_tasks": [
        ["id": "b1", "type": "shell", "status": "running", "command": "sleep 120"]
      ],
    ]
    XCTAssertEqual(effectiveState("done", stdin: obj), "working")
  }

  /// done + running な bg サブエージェント → working。
  func testDoneWithRunningSubagentTaskBecomesWorking() {
    let obj: [String: Any] = [
      "background_tasks": [
        ["id": "a1", "type": "subagent", "status": "running", "agent_type": "general-purpose"]
      ]
    ]
    XCTAssertEqual(effectiveState("done", stdin: obj), "working")
  }

  /// done + background_tasks 空配列 → done（全作業完了後の Stop）。
  func testDoneWithEmptyBackgroundTasksStaysDone() {
    XCTAssertEqual(effectiveState("done", stdin: ["background_tasks": [[String: Any]]()]), "done")
  }

  /// done + background_tasks 欠落 → done（codex / agy の経路）。
  func testDoneWithoutBackgroundTasksStaysDone() {
    XCTAssertEqual(effectiveState("done", stdin: ["session_id": "s1"]), "done")
    XCTAssertEqual(effectiveState("done", stdin: nil), "done")
  }

  /// done + running でない要素のみ → done。
  func testDoneWithCompletedTasksStaysDone() {
    let obj: [String: Any] = [
      "background_tasks": [["id": "b1", "type": "shell", "status": "completed"]]
    ]
    XCTAssertEqual(effectiveState("done", stdin: obj), "done")
  }

  /// done + 混在配列（completed と running）→ working（"1 つでもあれば" の契約）。
  func testDoneWithMixedTasksSomeRunningBecomesWorking() {
    let obj: [String: Any] = [
      "background_tasks": [
        ["id": "b1", "type": "shell", "status": "completed"],
        ["id": "a1", "type": "subagent", "status": "running"],
      ]
    ]
    XCTAssertEqual(effectiveState("done", stdin: obj), "working")
  }

  /// done + background_tasks が配列でない型 → done（キャスト失敗は誤 working に倒さない）。
  func testDoneWithMalformedBackgroundTasksStaysDone() {
    XCTAssertEqual(effectiveState("done", stdin: ["background_tasks": "running"]), "done")
    XCTAssertEqual(
      effectiveState("done", stdin: ["background_tasks": [["status": 1]]]), "done")
  }

  /// done 以外の state は running があっても不変。
  func testNonDoneStateIsUnchanged() {
    let obj: [String: Any] = [
      "background_tasks": [["id": "b1", "type": "shell", "status": "running"]]
    ]
    XCTAssertEqual(effectiveState("working", stdin: obj), "working")
  }

  // MARK: sessionId(from:)

  /// claude/codex の "session_id" を返す。
  func testSessionIdFromSessionIdKey() {
    XCTAssertEqual(sessionId(from: ["session_id": "s1"]), "s1")
  }

  /// agy の "conversationId" へフォールバックする。
  func testSessionIdFallsBackToConversationId() {
    XCTAssertEqual(sessionId(from: ["conversationId": "c1"]), "c1")
  }

  /// どちらも無し・空文字・nil obj は nil。
  func testSessionIdMissingIsNil() {
    XCTAssertNil(sessionId(from: [:]))
    XCTAssertNil(sessionId(from: ["session_id": ""]))
    XCTAssertNil(sessionId(from: nil))
  }

  // MARK: parseHookJSON

  /// JSON オブジェクトはパースし、空・非 JSON は nil。
  func testParseHookJSON() {
    let obj = parseHookJSON(Data(#"{"session_id":"s1"}"#.utf8))
    XCTAssertEqual(obj?["session_id"] as? String, "s1")
    XCTAssertNil(parseHookJSON(Data()))
    XCTAssertNil(parseHookJSON(Data("not json".utf8)))
  }
}
