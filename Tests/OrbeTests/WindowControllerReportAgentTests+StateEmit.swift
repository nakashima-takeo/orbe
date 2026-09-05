import XCTest

@testable import Orbe

/// 報告経路（`report_agent`）が `agent_state` 制御イベントを **導出 `agentState` の実変化でだけ**
/// 流すことを、実 `WindowController` 駆動 ＋ wire 観測で固定する。消費・`consumeDoneState` 側の
/// 同じ契約は `AgentStateEmitTests`（ヘッドレス）が持つ。
///
/// 壊れると `orb wait` / MCP の待機系が「起きるべきでない報告で起きる」か「起きるべき遷移で
/// 永遠に起きない」のどちらかに倒れ、どちらも呼び出し側からは正常動作と区別がつかない。
/// 既存の `ControlWireTests+WaitForEvent` は `emit` を直叩きするので、slot の didSet が emit を
/// 駆動するというこの一元化そのものは、ここでしか測られない。
///
/// 「流れない」は実時間で待たず barrier で決定論的に示す——`emit` は control queue へ先に積まれ、
/// barrier の行はその後に書かれるので、イベントが起きていれば barrier より先に待機の応答が届く。
extension WindowControllerReportAgentTests {

  /// `agent_state` だけを、指定タブに絞って待つ。登録完了は barrier で確定させる
  /// （後続の報告が登録前に走らないことをここで決める）。tabId を省くと全タブを拾う。
  private func armAgentStateWait(_ wire: ControlWire, id: Int, tabId: Int? = nil) {
    var params: [String: Any] = ["kinds": ["agent_state"]]
    if let tabId { params["tabId"] = tabId }
    wire.send(["jsonrpc": "2.0", "id": id, "method": "wait_for_event", "params": params])
    wire.barrier()
  }

  /// 応答から `event` オブジェクトを取り出す。
  private func stateEvent(_ response: [String: Any]?) -> [String: Any]? {
    (response?["result"] as? [String: Any])?["event"] as? [String: Any]
  }

  // MARK: - 流れる

  /// 初回報告は報告 state を値に載せて 1 発流れる（`.none` → `.live`）。
  func testFirstReportEmitsAgentStateWithTheReportedValue() throws {
    let (wc, tab) = try makeControllerAndTab()
    let wire = ControlWire(target: nil)
    defer { wire.teardown() }
    armAgentStateWait(wire, id: 1, tabId: tab.id)

    wc.controlReportAgent(
      tab: tab, agent: "claude", state: "working", sessionId: nil, message: nil)

    let event = try XCTUnwrap(stateEvent(wire.nextResponse()))
    XCTAssertEqual(event["kind"] as? String, "agent_state")
    XCTAssertEqual(event["tabId"] as? Int, tab.id)
    XCTAssertEqual(event["value"] as? String, "working")
  }

  /// 同値の連続報告では流れず、次の実変化で流れる。sessionId の新値を載せた同値報告で
  /// 「slot は変わるが導出 state は変わらない」境界も同時に踏む。
  func testSameStateReportIsSilentAndTheNextRealChangeEmits() throws {
    let (wc, tab) = try makeControllerAndTab()
    let wire = ControlWire(target: nil)
    defer { wire.teardown() }
    wc.controlReportAgent(
      tab: tab, agent: "claude", state: "working", sessionId: "s-1", message: nil)
    armAgentStateWait(wire, id: 1, tabId: tab.id)

    wc.controlReportAgent(
      tab: tab, agent: "claude", state: "working", sessionId: "s-2", message: nil)
    wire.barrier()  // barrier が先に返る＝同値報告はイベントを出していない

    wc.controlReportAgent(
      tab: tab, agent: "claude", state: "waiting", sessionId: nil, message: nil)
    XCTAssertEqual(
      stateEvent(wire.nextResponse())?["value"] as? String, "waiting", "実変化では張った待機が起きる")
  }

  /// clear は「状態なし」を `report_agent` の入力と同じ語 `clear` で伝える——`orb wait --value clear`
  /// と `orb agent prompt` の `state clear` が同じ語で一致する。
  func testClearEmitsAnEventWithTheClearValue() throws {
    let (wc, tab) = try makeControllerAndTab()
    let wire = ControlWire(target: nil)
    defer { wire.teardown() }
    wc.controlReportAgent(
      tab: tab, agent: "claude", state: "working", sessionId: nil, message: nil)
    armAgentStateWait(wire, id: 1, tabId: tab.id)

    wc.controlReportAgent(tab: tab, agent: "claude", state: "clear", sessionId: nil, message: nil)

    let event = try XCTUnwrap(stateEvent(wire.nextResponse()))
    XCTAssertEqual(event["kind"] as? String, "agent_state")
    XCTAssertEqual(event["tabId"] as? Int, tab.id)
    XCTAssertEqual(event["value"] as? String, "clear", "報告の消滅は value に clear を載せる")
  }

  /// チケット消費直後（`.live(report: nil)`）に届く初回 hook は流れる——resume の本線で
  /// `orb wait` が最初の状態を取り逃さない。
  func testFirstHookAfterTicketConsumptionEmits() throws {
    let f = try makeControllerAndDormantTicket(command: "claude", sessionId: "resume-1")
    f.tab.recordMaterializationStarted()
    let wire = ControlWire(target: nil)
    defer { wire.teardown() }
    armAgentStateWait(wire, id: 1, tabId: f.tab.id)

    f.wc.controlReportAgent(
      tab: f.tab, agent: "claude", state: "working", sessionId: nil, message: nil)

    XCTAssertEqual(stateEvent(wire.nextResponse())?["value"] as? String, "working")
  }

  /// 見ているタブへの done 報告は、フォーカス消費で即 idle へ戻るが、履歴には done → idle の順で
  /// 両方が並ぶ。`orb wait --value done` は消費より先に done を掴める（消費が先に走ると done は
  /// 履歴に現れず、待つ側はタイムアウトまで気づけない）。
  func testDoneOnTheVisibleTabIsEmittedBeforeItsConsumptionToIdle() throws {
    let (wc, tab) = try makeControllerAndTab()
    makeKey(wc)
    let wire = ControlWire(target: nil)
    defer { wire.teardown() }
    for (id, value) in [(1, "done"), (2, "idle")] {
      wire.send([
        "jsonrpc": "2.0", "id": id, "method": "wait_for_event",
        "params": ["kinds": ["agent_state"], "tabId": tab.id, "value": value],
      ])
    }
    wire.barrier()

    wc.controlReportAgent(
      tab: tab, agent: "claude", state: "done", sessionId: nil, message: AgentMessage(text: "d"))

    XCTAssertEqual(tab.agentState, "idle", "前提: 見ているタブの done はフォーカス消費される")
    let done = try XCTUnwrap(stateEvent(wire.nextResponse()))
    let idle = try XCTUnwrap(stateEvent(wire.nextResponse()))
    XCTAssertEqual(done["value"] as? String, "done", "消費前の done が先に流れる")
    XCTAssertEqual(idle["value"] as? String, "idle", "消費後の idle が後に流れる")
    XCTAssertLessThan(
      try XCTUnwrap(done["seq"] as? Int), try XCTUnwrap(idle["seq"] as? Int),
      "履歴は done → idle の順")
  }

  // MARK: - 流れない

  /// 一度も報告のないタブへの clear は流れない（状態なし → 状態なしで実変化がない）。
  func testClearOnAgentlessTabEmitsNothing() throws {
    let (wc, tab) = try makeControllerAndTab()
    let wire = ControlWire(target: nil)
    defer { wire.teardown() }
    armAgentStateWait(wire, id: 1, tabId: tab.id)

    wc.controlReportAgent(tab: tab, agent: "claude", state: "clear", sessionId: nil, message: nil)

    wire.barrier()
  }

  /// 消費直後（報告前）のタブへ SessionEnd の clear が来ても流れない（resume 直後に起きる実経路）。
  func testClearBeforeTheFirstHookEmitsNothing() throws {
    let f = try makeControllerAndDormantTicket(command: "claude", sessionId: "resume-1")
    f.tab.recordMaterializationStarted()
    let wire = ControlWire(target: nil)
    defer { wire.teardown() }
    armAgentStateWait(wire, id: 1, tabId: f.tab.id)

    f.wc.controlReportAgent(
      tab: f.tab, agent: "claude", state: "clear", sessionId: nil, message: nil)

    wire.barrier()
  }

  /// 休眠チケット宛の偽 report はイベントを出さない。dormant タブには報告主のプロセスが
  /// 存在しえないので、ここで流すと待機系が実体のない状態変化で起きる。
  func testForgedReportToDormantTicketEmitsNothing() throws {
    let f = try makeControllerAndDormantTicket(command: "claude", sessionId: "resume-1")
    let wire = ControlWire(target: nil)
    defer { wire.teardown() }
    armAgentStateWait(wire, id: 1, tabId: f.tab.id)

    f.wc.controlReportAgent(
      tab: f.tab, agent: "codex", state: "waiting", sessionId: "forged",
      message: AgentMessage(text: "synthetic"))

    wire.barrier()
  }

  /// 休眠チケット宛の clear もイベントを出さない（破棄は state を問わない）。
  func testClearToDormantTicketEmitsNothing() throws {
    let f = try makeControllerAndDormantTicket(command: "claude", sessionId: "resume-1")
    let wire = ControlWire(target: nil)
    defer { wire.teardown() }
    armAgentStateWait(wire, id: 1, tabId: f.tab.id)

    f.wc.controlReportAgent(
      tab: f.tab, agent: "claude", state: "clear", sessionId: nil, message: nil)

    wire.barrier()
  }
}
