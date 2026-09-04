import Foundation
import XCTest

@testable import Orbe

/// エージェント起動 2 メソッド（`spawn_agent` / `resume_agent`）の params と応答を wire 上で固定する。
///
/// method 名・必須 param・ドメイン失敗の素通しは `+Params` / `+Methods` の共有表が持ち、ここは
/// **ガードの無い optional の到達**と**戻り値に sessionId を含めないこと**という、この 2 つに固有の
/// 契約だけを見る。どちらも表では観測できない（届かなくてもエラーにならない・余分なキーがあっても
/// エラーにならない）。
extension ControlWireTests {
  /// `spawn_agent` の optional 3 件が名前どおり target へ届く（`command` にもガードが無い＝
  /// 省略を「デフォルトを解け」の意味として target へ渡すため、ここでしか到達を観測できない）。
  /// `command` に非文字列を渡した形だけは「省略」と同じにせず -32602 で弾く——通すと、指定した
  /// のとは違う（デフォルトの）agent が黙って起きる。
  func testSpawnAgentOptionalParamsReachTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(
      id: 1, method: "spawn_agent",
      params: ["command": "codex", "workspaceId": 3, "cwd": "/tmp/cwd"])
    let spawn = fake.agentSpawns.last
    XCTAssertEqual(spawn?.command, "codex", "command が名前どおり届く")
    XCTAssertEqual(spawn?.workspaceId, 3, "workspaceId が名前どおり届く")
    XCTAssertEqual(spawn?.cwd, "/tmp/cwd", "cwd が名前どおり届く")

    _ = wire.request(id: 2, method: "spawn_agent")
    XCTAssertNil(fake.agentSpawns.last?.command, "command 省略は nil のまま target へ渡る（デフォルト解決）")

    XCTAssertEqual(
      errorCode(wire.request(id: 3, method: "spawn_agent", params: ["command": 42])), -32602,
      "非文字列の command は省略と同じにしない")

    // 非 Int の workspaceId も「省略」と同じにしない——未知 id を -32004 で弾く契約なのに、
    // 型違いだけが黙ってアクティブ WS へ逸れると、指定と違う場所にタブが生える。
    XCTAssertEqual(
      errorCode(wire.request(id: 4, method: "spawn_agent", params: ["workspaceId": "3"])), -32602,
      "非 Int の workspaceId は省略と同じにしない")
  }

  /// `resume_agent` は `sessionId` を反響せず、4 つの param を名前どおり target へ渡す。
  /// `workspaceId` / `cwd` はガードが無いので、到達を観測できるのはここだけ。
  func testResumeAgentPassesCommandAndSessionIdToTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    let response = wire.request(
      id: 1, method: "resume_agent",
      params: [
        "command": "codex", "sessionId": "sess-42", "workspaceId": 7, "cwd": "/tmp/resume",
      ])
    XCTAssertEqual(fake.agentSpawns.last?.command, "codex", "command が名前どおり届く")
    XCTAssertEqual(fake.agentSpawns.last?.sessionId, "sess-42", "sessionId が名前どおり届く")
    XCTAssertEqual(fake.agentSpawns.last?.workspaceId, 7, "workspaceId が名前どおり届く")
    XCTAssertEqual(fake.agentSpawns.last?.cwd, "/tmp/resume", "cwd が名前どおり届く")
    XCTAssertNil(
      (response?["result"] as? [String: Any])?["sessionId"],
      "渡した sessionId を反響しない（実 ID の出所は list_panes の agentSessionId）")

    XCTAssertEqual(
      errorCode(
        wire.request(
          id: 2, method: "resume_agent",
          params: ["command": "codex", "sessionId": "s", "workspaceId": "3"])), -32602,
      "非 Int の workspaceId は省略と同じにしない")
  }
}
