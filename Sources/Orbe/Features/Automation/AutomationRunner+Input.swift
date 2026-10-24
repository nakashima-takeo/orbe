import Foundation

extension AutomationRunner {
  /// 役割の入力を組む唯一の場所。取得と仕事は行の席を持たない入力なので、ツールを持ちうる agent へ上流の行は渡らない
  /// （読みは起こすかの門にだけ使う）。
  func input(
    _ node: AutomationGraph.Node, _ automation: Automation, _ read: AutomationIntake.Read?
  ) -> AutomationNodePass.Input {
    let state = automation.state(node.id)
    let rows = (read?.taken ?? []).map {
      AutomationNodeRow(id: $0.id, text: $0.text, origin: $0.origin, source: $0.source)
    }
    switch node.role {
    case .fetch:
      return .fetch(since: state.succeededAt)
    case .work:
      return .work
    case .process:
      return .process(rows, reachesJudge: automation.graph.reachesTaskCandidates(node.id))
    case .judge:
      // 判定の出どころの無い行は、読むときに捨ててある。
      let sourced = rows.compactMap { row in
        row.origin.map { AutomationSourcedRow(id: row.id, text: row.text, origin: $0) }
      }
      return .judge(
        sourced,
        choices: AutomationJudgeChoices(
          open: store.openProposals(of: automation.id, judge: node.id),
          workspaces: workspaces()))
    case .report:
      return .report(rows)
    case .sideEffect:
      return .sideEffect(rows, runId: Self.runId(automation.id, node.id, state.anchor))
    }
  }

  /// やり直しの鍵（`<自動化 ID>-<部品の ID>-<数え始めのミリ秒>`）。数え始めは記録された回でだけ進むので、止めた回・書けなかった
  /// 回のやり直しは同じ値になる。部品の鍵を変えても変わらない。
  static func runId(_ id: Int, _ part: AutomationNodeID, _ anchor: Date) -> String {
    "\(id)-\(part)-\(AutomationPersistence.millis(anchor))"
  }
}
