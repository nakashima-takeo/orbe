import Foundation
import Observation

/// agent の状態のうち、作業の札に出すもの。
enum WorktreeAgentState: Equatable {
  case working, waiting
}

/// worktree ごとの、そこで作業中か入力待ちの agent（@Observable・main のみ・窓に 1 つ）。タブは観測できない
/// 値なので、画面がタブを直接読むと描き直しが他の変化のついでに左右される。chrome の更新の合流点
/// （`flushChrome`）が全タブからこの索引を作り直し、値が変わったときだけ書く。タスク画面と ⌘T が読む。
@Observable final class WorktreeAgentActivity {
  struct Agent: Equatable {
    /// agent の command 名（`claude`）。
    let name: String
    let state: WorktreeAgentState
    /// その状態になった時刻（経過の表示）。
    let since: Date
    let tabId: Int
    /// タブの表示名。
    let tabTitle: String
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

  /// 同じ worktree に複数あれば 1 つにまとめる。入力待ちを優先し（人の手が要る）、同じ状態なら、その状態に
  /// なったのが新しい方。
  static func index(_ tabs: [(key: String, agent: Agent)]) -> [String: Agent] {
    var index: [String: Agent] = [:]
    for (key, agent) in tabs {
      guard let other = index[key] else {
        index[key] = agent
        continue
      }
      if agent.state != other.state {
        if agent.state == .waiting { index[key] = agent }
      } else if agent.since > other.since {
        index[key] = agent
      }
    }
    return index
  }
}
