import Foundation

extension AutomationRunner {
  /// 役割の入力を組む唯一の場所。取得と仕事は行の席を持たない入力なので、ツールを持ちうる agent へ上流の行は渡らない
  /// （読みは起こすかの門にだけ使う）。
  func input(
    _ node: AutomationGraph.Node, _ automation: Automation, _ read: AutomationIntake.Read?
  ) -> AutomationNodePass.Input {
    let state = automation.state(node.id)
    let rows = (read?.taken ?? []).map {
      AutomationNodeRow(id: $0.id, text: $0.text, ref: $0.ref, source: $0.source)
    }
    switch node.role {
    case .fetch:
      return .fetch(
        since: state.succeededAt, reachesJudge: automation.graph.reachesTaskCandidates(node.id))
    case .work:
      return .work
    case .process:
      return .process(rows, reachesJudge: automation.graph.reachesTaskCandidates(node.id))
    case .judge:
      return .judge(
        rows,
        choices: AutomationJudgeChoices(
          open: store.openProposals(of: node.id), workspaces: workspaces()))
    case .report:
      return .report(rows)
    case .sideEffect:
      return .sideEffect(rows, runId: Self.runId(automation.id, node.id, state.recordedAnchor))
    }
  }

  /// やり直しの鍵（`<自動化 ID>-<ノードの ID>-<記録の数え始めのミリ秒>`）。記録の数え始め（`recordedAnchor`）は記録された回でだけ
  /// 進むので、止めた回・書けなかった回のやり直しは同じ値になる——番人の数え始めは書けなかった回の後も進むので使わない。ノードの
  /// 鍵を変えても変わらない。
  static func runId(_ id: Int, _ nodeId: AutomationNodeID, _ anchor: Date) -> String {
    "\(id)-\(nodeId)-\(AutomationPersistence.millis(anchor))"
  }
}
