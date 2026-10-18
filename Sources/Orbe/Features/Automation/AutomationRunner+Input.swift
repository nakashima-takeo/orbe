import Foundation

extension AutomationRunner {
  /// 役割の入力を組む唯一の場所。取得と仕事は行の席を持たない入力なので、ツールを持ちうる agent へ溜まりの行は渡らない
  /// （溜まりは起こすかの門にだけ使う）。行を読む役割で、取った行が 1 つも読めなければ nil。
  func input(
    _ node: AutomationGraph.Node, _ automation: Automation, _ take: AutomationInbox.Take?
  ) throws(AutomationError) -> AutomationPartPass.Input? {
    let state = automation.state(node.key)
    var rows: [AutomationPartRow] = []
    switch node.role {
    case .process, .judge, .report, .sideEffect:
      if let take {
        rows = try store.rows(take.taken)
        guard !rows.isEmpty else { return nil }
      }
    case .fetch, .work:
      break
    }
    switch node.role {
    case .fetch:
      return .fetch(since: state.succeededAt, lastOutput: Set(state.lastOutput.map(\.id)))
    case .work:
      return .work
    case .process:
      return .process(rows, reachesJudge: automation.graph.reachesTaskCandidates(node.key))
    case .judge:
      // 判定の溜まりの出どころの無い行は、取るときに捨ててある。
      let sourced = rows.compactMap { row in
        row.origin.map { AutomationSourcedRow(id: row.id, text: row.text, origin: $0) }
      }
      return .judge(
        sourced,
        choices: AutomationJudgeChoices(
          open: store.openProposals(of: automation.id, judge: node.key),
          workspaces: workspaces()))
    case .report:
      return .report(rows)
    case .sideEffect:
      return .sideEffect(rows, runId: Self.runId(automation.id, node.key, state.anchor))
    }
  }

  /// 回の ID（`<自動化 ID>-<部品の鍵>-<数え始めのミリ秒>`）。数え始めは記録された回でだけ進むので、止めた回・書けなかった回の
  /// やり直しは同じ ID になる。
  static func runId(_ id: Int, _ part: String, _ anchor: Date) -> String {
    "\(id)-\(part)-\(AutomationPersistence.millis(anchor))"
  }
}
