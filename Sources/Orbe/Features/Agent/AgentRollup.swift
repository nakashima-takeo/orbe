import Foundation

/// 全 workspace・全タブ・全ペインを横断したエージェント状態の件数集計。
/// 件数の単位はペイン＝`agentState` を持つ `SurfaceView` 1 つを 1 件（TerminalController が数える）。
enum AgentRollup {
  /// 横断ロールアップが扱う状態種別の固定順（working → waiting → done → idle）。
  /// idle はタブには出さない（`aggregateAgentState` の priority が除外）が、横断集計には数えて出す。
  /// 件数の集計対象もこの集合（`countedStates`）で、集計と表示の対象を一致させる。
  static let stateOrder = ["working", "waiting", "done", "idle"]

  /// タブ/workspace 名の色を決める「最優先状態」の優先順位（waiting > working > done）。
  /// idle は畳み込み対象外。表示順の `stateOrder` とは用途が異なる別概念。
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
  /// この workspace の全タブ・全ペインを状態種別ごとに件数集計する（`[state: count]`）。
  func agentCounts() -> [String: Int] {
    var counts: [String: Int] = [:]
    for tab in tabs {
      for (state, count) in tab.agentStateCounts() { counts[state, default: 0] += count }
    }
    return counts
  }

  /// この workspace が永続している agent != nil leaf の総数（休眠 agent 数）。
  /// 未起動（activated==false）行の zzz 表示に使う。既存 agentCounts() は agentState 基準で
  /// 休眠行では 0 になるため、この永続 leaf 基準の別カウントが要る。
  func dormantAgentCount() -> Int {
    tabs.reduce(0) { $0 + $1.restoredAgentCount }
  }
}
