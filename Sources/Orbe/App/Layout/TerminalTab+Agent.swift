import AppKit

/// タブのエージェント状態の読み（タブグリフ向け）と、`idle` への書き戻し。
/// スロットの所有・永続は本体（`TerminalTab`）が持つ。
extension TerminalTab {
  /// タブグリフに出す状態種別。`AgentRollup.priorityOrder`（waiting / working / done）のときだけ
  /// 種別を返し、idle・nil はグリフ無し（nil）——`AgentStateIcon.kind(state: "idle")` は `.idle` を
  /// 返すので、このフィルタを外すと done のフォーカス消費で idle グリフが残る。
  var agentStateKind: AgentStateIcon.Kind? {
    guard let state = agentState, AgentRollup.priorityOrder.contains(state) else { return nil }
    return AgentStateIcon.kind(state: state)
  }

  /// タブ活性化＝完了通知の消費。`done` を `idle`（休止）に遷移させ、done バッジを消す（idle は
  /// タブに出ない）。エージェントは生きて入力待ち＝休止なので、nil（不在）ではなく idle にして
  /// 横断集計に休止中として残す。`waiting`・`working` は残す。
  func consumeDoneState() { settleToIdle { $0 == "done" } }

  /// ユーザー操作（タブのコンテキストメニュー）によるリセット。waiting / working / done を `idle` へ
  /// 遷移させる。対象集合は `agentStateKind` がグリフを出す集合と同じ定数なので、
  /// 「グリフが出る ⇔ リセットできる」が一致する。
  func resetAgentState() { settleToIdle { AgentRollup.priorityOrder.contains($0) } }

  /// 述語を満たす state の live スロットだけ `idle` へ書き戻す。同一性（session）・文言・状態変化時刻は
  /// 運んだまま state だけ書き換えるため resume も Attention の並びも壊さない。
  /// `.dormant` / `.none` / 報告なしの `.live` は触らない。didSet が実変化を `agent_state` へ emit する。
  private func settleToIdle(where shouldSettle: (String) -> Bool) {
    guard case .live(let session, .some(var report)) = agentSlot, shouldSettle(report.state)
    else { return }
    report.state = "idle"
    agentSlot = .live(session: session, report: report)
  }
}
