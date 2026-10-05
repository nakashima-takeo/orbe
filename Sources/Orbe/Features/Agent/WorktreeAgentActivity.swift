import Foundation
import Observation

/// worktree ごとの、そこで動いている agent（@Observable・main のみ・窓に 1 つ）。タブは観測できない
/// 値なので、画面がタブを直接読むと描き直しが他の変化のついでに左右される。chrome の更新の合流点
/// （`flushChrome`）が全タブからこの索引を作り直し、値が変わったときだけ書く。タスク画面と ⌘T が読む。
@Observable final class WorktreeAgentActivity {
  struct Agent: Equatable {
    /// agent の command 名（`claude`）。
    let name: String
    /// 報告している状態（作業中・入力待ち・完了・休止）。
    let state: AgentStateIcon.Kind
    /// その状態になった時刻（経過の表示）。
    let since: Date
    let tabId: Int
    /// タブの表示名。
    let tabTitle: String
    /// その worktree が今 checkout しているブランチ（detached・git の外なら nil）。タスクが worktree を
    /// 付けたときのブランチと比べる。
    let branch: String?

    /// 行の札に出す状態（作業中か入力待ち）。完了・休止の agent は、詳細の agent の場所と ↵ でタブへ移る
    /// 先にだけ出る。
    var isBusy: Bool { state == .working || state == .waiting }
  }

  /// 場所のキー（タブの `groupKey`）→ その worktree の agent。
  private(set) var agents: [String: Agent]

  init(agents: [String: Agent] = [:]) {
    self.agents = agents
  }

  /// タブごとの (場所のキー, agent) から索引を作り直す。
  func update(_ tabs: [(key: String, agent: Agent)]) {
    let next = Self.index(tabs)
    if next != agents { agents = next }
  }

  /// 同じ worktree に複数あれば 1 つにまとめる。入力待ち > 作業中 > 完了 > 休止の順に優先し（人の手が要る
  /// ものから。タブのグリフを畳む `AgentRollup.priorityOrder` と同じ順の後ろに休止）、同じ状態なら、その状態に
  /// なったのが新しい方。
  static func index(_ tabs: [(key: String, agent: Agent)]) -> [String: Agent] {
    var index: [String: Agent] = [:]
    for (key, agent) in tabs {
      guard let other = index[key] else {
        index[key] = agent
        continue
      }
      let (rank, otherRank) = (Self.rank(agent.state), Self.rank(other.state))
      if rank < otherRank || (rank == otherRank && agent.since > other.since) {
        index[key] = agent
      }
    }
    return index
  }

  private static func rank(_ state: AgentStateIcon.Kind) -> Int {
    AgentRollup.priorityOrder.firstIndex(of: state.state) ?? AgentRollup.priorityOrder.count
  }
}
