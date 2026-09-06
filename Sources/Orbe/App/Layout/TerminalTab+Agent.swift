import AppKit

/// タブのエージェント状態の読み（タブグリフ向け）と、`idle` への書き戻しの入口。
/// スロットの所有・変異・永続は本体（`TerminalTab`）が持つ（書き戻しの実体は `settleReport`）。
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
  func consumeDoneState() { settleReport { $0 == "done" } }

  /// ユーザー操作（タブのコンテキストメニュー）によるリセット。waiting / working / done を `idle` へ
  /// 遷移させる。対象集合は `agentStateKind` がグリフを出す集合と同じ定数なので、
  /// 「グリフが出る ⇔ リセットできる」が一致する。
  func resetAgentState() { settleReport { AgentRollup.priorityOrder.contains($0) } }
}
