import Foundation
import XCTest

@testable import Orbe

/// `spawn_agent` / `resume_agent` の ready 待ち——idle を報告できる agent は起動より後の最初の
/// `agent_state=idle` を待ち、報告できない agent は即返す——の wire 契約を固定する。
/// 起動そのものと「どの agent が idle を報告できるか」の表は target / `AgentCatalog` の領分。
///
/// 壊れると何が起きるか: `orb agent spawn claude` が `ready:true` を返した直後の `prompt_agent` が
/// 起動前の PTY に打たれて消えるか、逆に codex の spawn が来ない idle を 30 秒待つ。`agentSessionId` が
/// 落ちれば resume の鍵を `list_panes` から拾い直す手順が戻る。時間切れが launch を捨てれば、
/// 実際には開いているタブの paneId を呼び出し側が知る手段が無くなる。
extension ControlWireTests {
  private func result(_ response: [String: Any]?) -> [String: Any]? {
    response?["result"] as? [String: Any]
  }

  /// 起動要求を送り、main 往復と待機の登録が済んだことを barrier で確定させる。
  private func launch(
    _ wire: ControlWire, id: Int, method: String, command: String, extra: [String: Any] = [:]
  ) {
    var params: [String: Any] = ["command": command]
    if method == "resume_agent" { params["sessionId"] = "sess-resume" }
    for (key, value) in extra { params[key] = value }
    wire.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    wire.barrier()
  }

  private func idle(_ paneId: Int, sessionId: String? = nil) -> ControlEvent {
    .agentState(paneId: paneId, state: "idle", message: nil, sessionId: sessionId)
  }

  // MARK: - idle を報告できる agent

  /// claude は起動より後の最初の idle を待ってから、launch ＋ `ready:true` ＋ `agentSessionId` ＋
  /// そのイベントの `seq` で返る。spawn と resume で同じ形。
  func testIdleReportingAgentWaitsForItsFirstIdleAndReturnsTheSession() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    // Fake は spawn を pane 4343、resume を pane 4346 に起こす。
    for (index, entry) in [("spawn_agent", 4343), ("resume_agent", 4346)].enumerated() {
      let id = 1 + index * 10
      launch(wire, id: id, method: entry.0, command: "claude")
      XCTAssertEqual(fake.agentSpawns.count, index + 1, "前提: \(entry.0) は起動まで済んでいる")

      ControlServer.shared.emit(
        .agentState(paneId: entry.1, state: "working", message: nil, sessionId: "s"))
      ControlServer.shared.emit(idle(entry.1 + 1, sessionId: "other"))
      wire.barrier()  // idle 以外の状態・別ペインの idle では起きない

      let before = result(wire.request(id: id + 1, method: "list_workspaces"))?["seq"] as? Int ?? -1
      ControlServer.shared.emit(idle(entry.1, sessionId: "sess-\(entry.1)"))
      let response = wire.nextResponse()
      XCTAssertEqual(response?["id"] as? Int, id, "\(entry.0) は自分の id で起きる")
      let launched = result(response)
      XCTAssertEqual(launched?["paneId"] as? Int, entry.1, "\(entry.0) の launch が載る")
      XCTAssertNotNil(launched?["tabId"] as? Int)
      XCTAssertNotNil(launched?["workspaceId"] as? Int)
      XCTAssertEqual(
        (launched?["agent"] as? [String: Any])?["command"] as? String, "claude")
      XCTAssertEqual(launched?["ready"] as? Bool, true, "\(entry.0) は idle を見て ready:true")
      XCTAssertEqual(
        launched?["agentSessionId"] as? String, "sess-\(entry.1)",
        "\(entry.0) の agentSessionId は idle 報告が運んだ session id")
      let seq = launched?["seq"] as? Int ?? -1
      XCTAssertGreaterThan(seq, before, "\(entry.0) の seq はその idle イベントの seq（起動時点より後）")
      XCTAssertLessThanOrEqual(
        seq, result(wire.request(id: id + 2, method: "list_workspaces"))?["seq"] as? Int ?? -1,
        "\(entry.0) の seq は履歴の中の位置")
    }
  }

  /// idle 報告に session id が無ければ `agentSessionId` キーを落とす（null を置かない）。
  func testIdleWithoutSessionIdOmitsAgentSessionId() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    launch(wire, id: 1, method: "spawn_agent", command: "claude")
    ControlServer.shared.emit(idle(4343))
    let launched = result(wire.nextResponse())

    XCTAssertEqual(launched?["ready"] as? Bool, true, "前提: idle で起きている")
    XCTAssertNil(launched?["agentSessionId"], "session id 無しなら agentSessionId キーを落とす")
  }

  // MARK: - 報告できない agent

  /// codex / agy は待たずに launch ＋ `ready:false` で即返り、`agentSessionId` を持たない。
  func testAgentThatCannotReportIdleReturnsAtOnceWithReadyFalse() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    for (index, command) in ["codex", "agy"].enumerated() {
      let launched = result(
        wire.request(id: 1 + index, method: "spawn_agent", params: ["command": command]))
      XCTAssertEqual(launched?["paneId"] as? Int, 4343, "\(command) の launch が載る")
      XCTAssertEqual(launched?["ready"] as? Bool, false, "\(command) は idle を待たず ready:false")
      XCTAssertNil(launched?["agentSessionId"], "\(command) は agentSessionId を持たない")
      XCTAssertNil(launched?["timedOut"], "即返りは時間切れではない（timedOut を置かない）")
      XCTAssertNotNil(launched?["seq"] as? Int, "成功応答なので seq を持つ")
    }
  }

  // MARK: - 打ち切り

  /// 時間切れは launch を捨てず `ready:false, timedOut:true` を重ねる（spawn は成功している）。
  func testReadyTimeoutKeepsTheLaunchAndFlagsTimedOut() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    let launched = result(
      wire.request(id: 1, method: "spawn_agent", params: ["command": "claude", "timeoutMs": 50]))

    XCTAssertEqual(launched?["paneId"] as? Int, 4343, "時間切れでも開いたタブの宛先を返す")
    XCTAssertEqual(launched?["ready"] as? Bool, false)
    XCTAssertEqual(launched?["timedOut"] as? Bool, true, "「報告できない agent」と区別する印")
    XCTAssertNil(launched?["agentSessionId"])
  }

  /// 待機中にそのペインが閉じたら -32000 "agent exited"（起動失敗で即終了した形）。
  func testPaneClosedWhileWaitingForReadyIsAgentExited() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    launch(wire, id: 1, method: "spawn_agent", command: "claude")
    ControlServer.shared.emit(.paneClosed(paneId: 4343))
    let response = wire.nextResponse()

    XCTAssertEqual(errorCode(response), -32000)
    XCTAssertEqual(
      (response?["error"] as? [String: Any])?["message"] as? String, "agent exited")
  }

  /// `timeoutMs` の不備は起動する前に -32602（タブを開いてから弾かない）。
  func testInvalidTimeoutIsRejectedBeforeLaunching() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    var id = 0

    for bad in [0, -1, 86_400_001, "50"] as [Any] {
      id += 1
      XCTAssertEqual(
        errorCode(
          wire.request(
            id: id, method: "spawn_agent", params: ["command": "codex", "timeoutMs": bad])),
        -32602, "timeoutMs \(bad) は -32602")
    }
    XCTAssertTrue(fake.agentSpawns.isEmpty, "弾いた要求はタブを開いていない")
  }
}
