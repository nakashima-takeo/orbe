import AppKit

/// タブ内ペインのエージェント状態の読み（タブグリフ・横断ロールアップ向けの集約）と、
/// `idle` への書き戻し。分割ツリーの構築・フォーカス・永続は本体（`TerminalController`）が持つ。
extension TerminalController {
  /// タブ内の全ペインを優先順位 `waiting > working > done` で1つに畳んだ状態種別。
  /// idle・nil のみならグリフ無し（nil）。
  func aggregateAgentState() -> AgentStateIcon.Kind? {
    let priority = AgentRollup.priorityOrder
    var winner: SurfaceView?
    var winnerRank = priority.count
    forEachPane(in: rootContainer) { pane in
      guard let state = pane.agentState, let rank = priority.firstIndex(of: state) else { return }
      if rank < winnerRank {
        winnerRank = rank
        winner = pane
      }
    }
    guard let winner else { return nil }
    return AgentStateIcon.kind(state: winner.agentState)
  }

  /// このタブのペインのエージェント状態を状態種別ごとに件数集計する（`[state: count]`）。
  /// 件数の単位はペイン＝`agentState` を持つ `SurfaceView` 1 つを 1 件。
  /// 数えるのはロールアップが表示する状態のみ（`AgentRollup.countedStates`）＝集計と表示が一致する。
  func agentStateCounts() -> [String: Int] {
    var counts: [String: Int] = [:]
    forEachPane(in: rootContainer) { pane in
      guard let state = pane.agentState, AgentRollup.countedStates.contains(state) else { return }
      counts[state, default: 0] += 1
    }
    return counts
  }

  /// タブ活性化＝完了通知の消費。タブ内全ペインの `done` を `idle`（休止）に遷移させ、
  /// 集約 `done` バッジを消す（idle はタブに出ない）。エージェントは生きて入力待ち＝休止なので、
  /// nil（不在）ではなく idle にして横断集計に休止中として残す。`waiting`・`working` は残す。
  /// 同一性（session）と報告の文言・時刻は運んだまま state だけ書き換えるため resume も
  /// Attention の並びも壊さない。
  func consumeDoneState() {
    forEachPane(in: rootContainer) { pane in
      guard case .live(let session, .some(var report)) = pane.agentSlot, report.state == "done"
      else { return }
      report.state = "idle"
      pane.agentSlot = .live(session: session, report: report)  // didSet が done→idle を emit
    }
  }
}
