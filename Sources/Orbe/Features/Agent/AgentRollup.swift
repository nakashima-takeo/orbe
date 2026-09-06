import Foundation

/// 全 workspace の activated タブを横断したエージェント状態の件数集計。
/// 件数の単位はタブ＝`agentState` を持つ `TerminalTab` 1 つを 1 件。
enum AgentRollup {
  /// 横断ロールアップが扱う状態種別の固定順（working → waiting → done → idle）。
  /// idle はタブには出さない（`agentStateKind` の priority が除外）が、横断集計には数えて出す。
  /// 件数の集計対象もこの集合（`countedStates`）で、集計と表示の対象を一致させる。
  /// `dormant` は `agentState` ではなく未消費の復元チケット（`.dormant` slot）の数なので、ここには入れない。
  /// 表示上は workspace パレットだけが、この順の後ろへ 1 件連結する（`Workspace.paletteLiveState()`）。
  static let stateOrder = ["working", "waiting", "done", "idle"]

  /// タブグリフに出す（＝リセットできる）状態の集合（`TerminalTab.agentStateKind` / `resetAgentState`）。
  /// 順序は Dispatch が同じ worktree の複数タブを 1 状態へ畳むときだけ使う（waiting > working > done、
  /// `DispatchWorktreeClassifier`）。idle はどちらにも入らない。表示順の `stateOrder` とは用途が異なる別概念。
  static let priorityOrder = ["waiting", "working", "done"]

  /// 件数に数える状態種別。これ以外（nil 等）はロールアップに数えない。
  static let countedStates = Set(stateOrder)

  /// 全 workspace 合算（grand total）。右上バー用。
  static func grandTotal(of workspaces: [Workspace]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for ws in workspaces {
      for (state, count) in ws.agentCounts() { counts[state, default: 0] += count }
    }
    return counts
  }

  /// `[state: count]` を `stateOrder` の順に並べる。件数 0 の種別は落とす。
  static func ordered(_ counts: [String: Int]) -> [(state: String, count: Int)] {
    stateOrder.compactMap { state in
      guard let count = counts[state], count > 0 else { return nil }
      return (state, count)
    }
  }
}

extension Workspace {
  /// この workspace の activated タブだけを状態種別ごとに件数集計する（`[state: count]`）。
  /// 数えるのはロールアップが表示する状態のみ（`AgentRollup.countedStates`）＝集計と表示が一致する。
  func agentCounts() -> [String: Int] {
    var counts: [String: Int] = [:]
    for tab in tabs where tab.activated {
      guard let state = tab.agentState, AgentRollup.countedStates.contains(state) else { continue }
      counts[state, default: 0] += 1
    }
    return counts
  }

  /// この workspace に現在残る、未消費の復元チケット（休眠 agent）の総数。
  /// `.dormant` なタブを数えるだけ——チケットは materialize 開始で必ず消費されるため、
  /// activated タブに休眠は残らない。live / dormant が混在する間は正の値を返す。
  func dormantAgentCount() -> Int {
    tabs.count(where: \.isDormant)
  }
}
