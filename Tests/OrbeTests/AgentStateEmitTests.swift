import XCTest

@testable import Orbe

/// 報告以外の slot 遷移——復元での休眠チケット代入・チケット消費・`consumeDoneState`・
/// `resetAgentStates`——が `agent_state` 制御イベントをどう出す（出さない）かを固定する。
/// 報告経路の同じ契約は `WindowControllerReportAgentTests+StateEmit` が持つ。
///
/// 壊れると、`orb wait` / MCP の待機系がタブを起こしただけで起きる（復元・消費は状態変化ではない）か、
/// idle への書き戻しを取り逃す。どちらも呼び出し側からは正常動作と区別がつかない。
///
/// `TerminalController` は window 未接続なら libghostty surface を生成しないため、ここは純ロジック
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
  private let resume: TerminalController.ResumeSpawn = { _ in ("claude --resume x", [:]) }
  /// resume を解決できない resolver（休眠チケットが素シェルへ落ちる枝）。
  private let noResume: TerminalController.ResumeSpawn = { _ in nil }

  /// `agent_state` の待機を張り、登録完了を barrier で確定させる。paneId を省くのは、
  /// 復元前で ID がまだ採番されていない場合（kind だけで全ペインを拾う）。
  private func armAgentStateWait(id: Int, paneId: Int? = nil) -> ControlWire {
    let w = wire ?? ControlWire(target: nil)
    wire = w
    var params: [String: Any] = ["kinds": ["agent_state"]]
    if let paneId { params["paneId"] = paneId }
    w.send(["jsonrpc": "2.0", "id": id, "method": "wait_for_event", "params": params])
    w.barrier()
    return w
  }

  /// 応答から `event` オブジェクトを取り出す。
  private func stateEvent(_ response: [String: Any]?) -> [String: Any]? {
    (response?["result"] as? [String: Any])?["event"] as? [String: Any]
  }

  /// 休眠チケットの葉と素の葉を並べた復元ツリー。消費の 2 枝と `.none` の素通りを 1 本で踏める。
  private var mixedTree: PaneNode {
    .split(
      vertical: true, ratio: 0.5,
      first: .leaf(cwd: "/w", agent: AgentSession(command: "claude", sessionId: "resume-1")),
      second: .leaf(cwd: "/w", agent: nil))
  }

  // MARK: - 復元と消費（状態変化ではない＝流れない）

  /// 復元で休眠チケットを立てても、それを消費して live へ移しても、イベントは流れない。
  /// どちらも「報告された状態」を変えていないので、待機系はタブを起こしただけでは起きない。
  func testRestoreAndTicketConsumptionEmitNothing() throws {
    let w = armAgentStateWait(id: 1)

    let tc = TerminalController(restoring: mixedTree, resumeSpawn: resume)
    tc.recordMaterializationStarted()

    w.barrier()
    let panes = tc.controlAllPanes()
    XCTAssertEqual(
      panes[0].agentSlot,
      .live(session: AgentSession(command: "claude", sessionId: "resume-1"), report: nil),
      "前提: チケットは消費されて live へ移っている")
    XCTAssertEqual(panes[1].agentSlot, .none, "前提: 素の葉は消費を素通りする")
  }

  /// resume を解決できないチケットの消費（素シェル化）でも流れない。
  func testUnresolvableTicketConsumptionEmitsNothing() throws {
    let w = armAgentStateWait(id: 1)

    let tc = TerminalController(
      restoring: .leaf(cwd: "/w", agent: AgentSession(command: "unknown", sessionId: "x")),
      resumeSpawn: noResume)
    tc.recordMaterializationStarted()

    w.barrier()
    XCTAssertEqual(tc.controlAllPanes()[0].agentSlot, .none, "前提: 素シェルへ落ちている")
  }

  // MARK: - consumeDoneState

  /// done のフォーカス消費（done → idle）は実変化なので `idle` を載せて流れる。
  func testConsumeDoneStateEmitsIdle() throws {
    let tc = TerminalController()
    let pane = try XCTUnwrap(tc.focusedPane)
    setReportedState(pane, "done")
    let w = armAgentStateWait(id: 1, paneId: pane.id)

    tc.consumeDoneState()

    let event = try XCTUnwrap(stateEvent(w.nextResponse()))
    XCTAssertEqual(event["kind"] as? String, "agent_state")
    XCTAssertEqual(event["paneId"] as? Int, pane.id)
    XCTAssertEqual(event["value"] as? String, "idle")
  }

  /// done でないペインしか無いタブの消費では流れない（waiting・報告前の live・素のシェル）。
  func testConsumeDoneStateEmitsNothingWithoutADonePane() throws {
    let tc = TerminalController()
    tc.split(.horizontal)
    tc.split(.vertical, from: try XCTUnwrap(tc.controlAllPanes().first))
    let panes = tc.controlAllPanes()
    XCTAssertEqual(panes.count, 3, "前提: 3 ペイン（waiting / 報告前の live / 素のシェル）")
    setReportedState(panes[0], "waiting")
    panes[1].agentSlot = .live(
      session: AgentSession(command: "claude", sessionId: "resume-1"), report: nil)
    let w = armAgentStateWait(id: 1)

    tc.consumeDoneState()

    w.barrier()
  }

  // MARK: - resetAgentStates

  /// タブのコンテキストメニューからの一括リセットは、実変化したペインの `idle` を載せて流れる。
  func testResetAgentStatesEmitsIdle() throws {
    let tc = TerminalController()
    let pane = try XCTUnwrap(tc.focusedPane)
    setReportedState(pane, "waiting")
    let w = armAgentStateWait(id: 1, paneId: pane.id)

    tc.resetAgentStates()

    let event = try XCTUnwrap(stateEvent(w.nextResponse()))
    XCTAssertEqual(event["kind"] as? String, "agent_state")
    XCTAssertEqual(event["paneId"] as? Int, pane.id)
    XCTAssertEqual(event["value"] as? String, "idle")
  }

  /// リセットできる状態のペインが無いタブでは流れない（idle・報告前の live・素のシェル）。
  func testResetAgentStatesEmitsNothingWithoutAResettablePane() throws {
    let tc = TerminalController()
    tc.split(.horizontal)
    tc.split(.vertical, from: try XCTUnwrap(tc.controlAllPanes().first))
    let panes = tc.controlAllPanes()
    XCTAssertEqual(panes.count, 3, "前提: 3 ペイン（idle / 報告前の live / 素のシェル）")
    setReportedState(panes[0], "idle")
    panes[1].agentSlot = .live(
      session: AgentSession(command: "claude", sessionId: "resume-1"), report: nil)
    let w = armAgentStateWait(id: 1)

    tc.resetAgentStates()

    w.barrier()
  }
}
