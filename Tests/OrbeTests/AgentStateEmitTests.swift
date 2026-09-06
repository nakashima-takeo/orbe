import XCTest

@testable import Orbe

/// 報告以外の slot 遷移——復元での休眠チケット代入・チケット消費・`consumeDoneState`・
/// `resetAgentState`——が `agent_state` 制御イベントをどう出す（出さない）かを固定する。
/// 報告経路の同じ契約は `WindowControllerReportAgentTests+StateEmit` が持つ。
///
/// 壊れると、`orb wait` / MCP の待機系がタブを起こしただけで起きる（復元・消費は状態変化ではない）か、
/// idle への書き戻しを取り逃す。どちらも呼び出し側からは正常動作と区別がつかない。
///
/// `TerminalTab` は window 未接続なら libghostty surface を生成しないため、ここは純ロジック
/// として駆動できる（GhosttyKit ランタイムは起動しない）。他のイベント源を持たないので、
/// 「流れない」を barrier で決定論的に示せる。
final class AgentStateEmitTests: OrbeTestCase {
  /// 駆動台。後始末は `tearDown` が持つ。
  private var wire: ControlWire?

  override func tearDown() {
    wire?.teardown()
    wire = nil
    super.tearDown()
  }

  /// resume を必ず解決する resolver（休眠チケットが `.live` へ消費される枝）。
  private let resume: TerminalTab.ResumeSpawn = { _ in ("claude --resume x", [:]) }
  /// resume を解決できない resolver（休眠チケットが素シェルへ落ちる枝）。
  private let noResume: TerminalTab.ResumeSpawn = { _ in nil }

  /// `agent_state` の待機を張り、登録完了を barrier で確定させる。tabId を省くのは、
  /// 復元前で ID がまだ採番されていない場合（kind だけで全タブを拾う）。
  private func armAgentStateWait(id: Int, tabId: Int? = nil) -> ControlWire {
    let w = wire ?? ControlWire(target: nil)
    wire = w
    var params: [String: Any] = ["kinds": ["agent_state"]]
    if let tabId { params["tabId"] = tabId }
    w.send(["jsonrpc": "2.0", "id": id, "method": "wait_for_event", "params": params])
    w.barrier()
    return w
  }

  /// 応答から `event` オブジェクトを取り出す。
  private func stateEvent(_ response: [String: Any]?) -> [String: Any]? {
    (response?["result"] as? [String: Any])?["event"] as? [String: Any]
  }

  private let ticket = AgentSession(command: "claude", sessionId: "resume-1")

  // MARK: - 復元と消費（状態変化ではない＝流れない）

  /// 復元で休眠チケットを立てても、それを消費して live へ移しても、イベントは流れない。
  /// どちらも「報告された状態」を変えていないので、待機系はタブを起こしただけでは起きない。
  /// 素のタブの消費（`.none` の素通り）も同じく流れない。
  func testRestoreAndTicketConsumptionEmitNothing() throws {
    let w = armAgentStateWait(id: 1)

    let dormant = TerminalTab(
      restoring: TabState(cwd: "/w", agent: ticket, explicitTitle: nil), resumeSpawn: resume)
    dormant.recordMaterializationStarted()
    let plain = TerminalTab(
      restoring: TabState(cwd: "/w", agent: nil, explicitTitle: nil), resumeSpawn: resume)
    plain.recordMaterializationStarted()

    w.barrier()
    XCTAssertEqual(
      dormant.agentSlot, .live(session: ticket, report: nil),
      "前提: チケットは消費されて live へ移っている")
    XCTAssertEqual(plain.agentSlot, .none, "前提: 素のタブは消費を素通りする")
  }

  /// resume を解決できないチケットの消費（素シェル化）でも流れない。
  func testUnresolvableTicketConsumptionEmitsNothing() throws {
    let w = armAgentStateWait(id: 1)

    let tab = TerminalTab(
      restoring: TabState(
        cwd: "/w", agent: AgentSession(command: "unknown", sessionId: "x"), explicitTitle: nil),
      resumeSpawn: noResume)
    tab.recordMaterializationStarted()

    w.barrier()
    XCTAssertEqual(tab.agentSlot, .none, "前提: 素シェルへ落ちている")
  }

  // MARK: - consumeDoneState

  /// done のフォーカス消費（done → idle）は実変化なので `idle` を載せて流れる。
  func testConsumeDoneStateEmitsIdle() throws {
    let tab = TerminalTab(cwd: "/tmp")
    setReportedState(tab, "done")
    let w = armAgentStateWait(id: 1, tabId: tab.id)

    tab.consumeDoneState()

    let event = try XCTUnwrap(stateEvent(w.nextResponse()))
    XCTAssertEqual(event["kind"] as? String, "agent_state")
    XCTAssertEqual(event["tabId"] as? Int, tab.id)
    XCTAssertEqual(event["value"] as? String, "idle")
  }

  /// done でないタブの消費では流れない（waiting・報告前の live・素のシェル）。
  func testConsumeDoneStateEmitsNothingWithoutADoneState() throws {
    let waiting = TerminalTab(cwd: "/tmp")
    setReportedState(waiting, "waiting")
    let unreported = liveUnreportedTab(session: ticket)
    let plain = TerminalTab(cwd: "/tmp")
    let w = armAgentStateWait(id: 1)

    for tab in [waiting, unreported, plain] { tab.consumeDoneState() }

    w.barrier()
  }

  // MARK: - resetAgentState

  /// タブのコンテキストメニューからのリセットは、実変化した `idle` を載せて流れる。
  func testResetAgentStatesEmitsIdle() throws {
    let tab = TerminalTab(cwd: "/tmp")
    setReportedState(tab, "waiting")
    let w = armAgentStateWait(id: 1, tabId: tab.id)

    tab.resetAgentState()

    let event = try XCTUnwrap(stateEvent(w.nextResponse()))
    XCTAssertEqual(event["kind"] as? String, "agent_state")
    XCTAssertEqual(event["tabId"] as? Int, tab.id)
    XCTAssertEqual(event["value"] as? String, "idle")
  }

  /// リセットできる状態の無いタブでは流れない（idle・報告前の live・素のシェル）。
  func testResetAgentStatesEmitsNothingWithoutAResettableState() throws {
    let idle = TerminalTab(cwd: "/tmp")
    setReportedState(idle, "idle")
    let unreported = liveUnreportedTab(session: ticket)
    let plain = TerminalTab(cwd: "/tmp")
    let w = armAgentStateWait(id: 1)

    for tab in [idle, unreported, plain] { tab.resetAgentState() }

    w.barrier()
  }
}
