import Foundation

/// ノードの 1 回の確定の中身（`AutomationStore.record` のトランザクションの中）。
struct AutomationRecording {
  let end: AutomationPassEnd
  let node: AutomationGraph.Node
  /// 自動化のメモリの位置。
  let index: Int
  let db: AutomationDatabase
  /// 回の履歴から数えられない捨てた数（持ち越し・読む前に期限で消えた数）。
  private var carriedDrops = AutomationDrops()
  private var written = AutomationDatabase.Written()

  init(end: AutomationPassEnd, node: AutomationGraph.Node, index: Int, db: AutomationDatabase) {
    self.end = end
    self.node = node
    self.index = index
    self.db = db
  }

  /// 確定する。成功した回は読んだ位置を進めて持ち越しを載せ、役割ごとの結果を書く。どちらの回も記録・回の履歴・外した印を書く。
  mutating func record(_ run: AutomationNodeRun, _ memory: inout AutomationMemory) throws
    -> AutomationRecorded
  {
    var run = run
    var judged: (proposals: [AutomationNodePass.Proposal], resolved: [String])?
    if !run.failed, case .succeeded(let output, _, _) = end.outcome {
      try consume(&run)
      switch output {
      case .judge(let proposals, let resolved): judged = (proposals, resolved)
      default: try produce(output, &run, &memory)
      }
    }
    let reconciled = try judged.map { try reconcile($0.proposals, $0.resolved, memory) }
    if let reconciled {
      run.result = .judge(
        proposed: reconciled.pending.count, resolved: reconciled.resolving.count,
        dismissed: reconciled.dismissed)
    }
    let recordId = try db.insert(run: run, of: end.nodeId, defId: end.defId, carried: carriedDrops)
    if let read = end.read {
      try db.insertInputs(
        of: recordId,
        read.taken.map { ($0.ref, "taken") } + read.dropped.map { ($0.row.ref, $0.reason.rawValue) }
      )
    }
    if let reconciled { try apply(reconciled, run: recordId, &memory) }
    try finish(run: recordId, endedAt: run.endedAt, &memory)
    let recorded = memory.automations[index].state(end.nodeId).runs.first { $0.id == recordId }
    return AutomationRecorded(changed: written.changed, run: recorded?.run)
  }

  /// 読んだ位置を進め、持ち越しを回の記録へ移す（下げた候補の数は判定の回の `withdrawn` へ）。
  private mutating func consume(_ run: inout AutomationNodeRun) throws {
    guard let read = end.read else { return }
    try db.advance(end.nodeId, read.reach)
    let carried = try db.carried(of: end.nodeId)
    carriedDrops.add(carried.dropped)
    carriedDrops.add(.lapsed, read.lapsed)
    if carried.withdrawn > 0 { run.withdrawn = carried.withdrawn }
    try db.setCarried(end.nodeId, AutomationCarried())
  }

  /// 判定でない役割の結果。取得・処理は出した行を照らし（今の集合は項目と版、出来事の流れは出来事）、無効にした項目と、今有効な
  /// 項目から抜けたリンクで判断待ちの候補を下げ、下げた数をこの回に数える。
  private mutating func produce(
    _ output: AutomationNodePass.Output, _ run: inout AutomationNodeRun,
    _ memory: inout AutomationMemory
  ) throws {
    switch output {
    case .fetch(let rows), .process(let rows):
      let outputs = rows.map {
        AutomationDatabase.Output(id: $0.id, body: $0.text, source: $0.source)
      }
      var lost = Set<String>()
      if node.coverage == .currentSet {
        lost = try db.liveLinks(of: end.nodeId)
        written = try db.writeItems(of: end.nodeId, outputs, at: run.endedAt)
        lost.subtract(try db.liveLinks(of: end.nodeId))
      } else {
        written = try db.writeEvents(of: end.nodeId, outputs, at: run.endedAt)
      }
      run.withdrawn = try memory.withdraw(
        after: written.invalidated, lost: [end.nodeId: lost], db, now: run.endedAt)
      run.result =
        node.role == .fetch
        ? .fetch(fresh: written.fresh, duplicates: written.duplicates)
        : .process(fresh: written.fresh, duplicates: written.duplicates)
    case .report(let text): run.result = .report(text: text)
    case .work(.done(let text)): run.result = .work(text: text, nothing: nil)
    case .work(.nothing(let reason)): run.result = .work(text: nil, nothing: reason)
    case .sideEffect: run.result = .sideEffect(count: run.execution.count)
    case .judge: break
    }
  }

  /// 判定の出力をこの時点の候補に当て直したもの。
  private struct Reconciled {
    let pending: [AutomationNodePass.Proposal]
    let resolving: [Int]
    let dismissed: [AutomationDismissal]
  }

  /// 回の途中に他の確定や人のさばきがあっても、この判定が同じリンクの候補を既に持つ案と、元にした行が今のものでなくなった案は
  /// 理由付きで捨て、この判定の判断待ちでない候補は対応済みにしない。
  private func reconcile(
    _ proposals: [AutomationNodePass.Proposal], _ resolved: [String], _ memory: AutomationMemory
  ) throws -> Reconciled {
    var proposed = memory.links(of: end.nodeId)
    var pending: [AutomationNodePass.Proposal] = []
    var resolving: [Int] = []
    var dismissed: [AutomationDismissal] = []
    for proposal in proposals {
      let link = proposal.fields.link
      if try db.noLongerCurrent(
        proposal.row, link: link, inputs: node.inputNodeIds,
        now: TaskItem.storedInstant(end.endedAt))
      {
        dismissed.append(AutomationDismissal(link: link, why: .noLongerCurrent))
        continue
      }
      guard proposed.insert(link).inserted else {
        dismissed.append(AutomationDismissal(link: link, why: .alreadyProposed))
        continue
      }
      pending.append(proposal)
    }
    for link in resolved {
      guard
        let open = memory.proposals.firstIndex(where: {
          $0.judge == end.nodeId && $0.link == link && $0.state == .open
        }),
        !resolving.contains(open)
      else {
        dismissed.append(AutomationDismissal(link: link, why: .noOpenProposal))
        continue
      }
      resolving.append(open)
    }
    return Reconciled(pending: pending, resolving: resolving, dismissed: dismissed)
  }

  /// 候補を足し（判定の回を指し、覚えている印を付ける）、対応済みにする。
  private func apply(_ reconciled: Reconciled, run recordId: Int, _ memory: inout AutomationMemory)
    throws
  {
    let endedAt = TaskItem.storedInstant(end.endedAt)
    for proposal in reconciled.pending {
      let proposalId = try db.insert(proposal: proposal, run: recordId, nodeId: end.nodeId)
      guard let originNodeId = try db.lineage(of: proposal.row).last?.nodeId else {
        throw AutomationError.unavailable("the row of proposal \(proposalId) is missing")
      }
      memory.proposals.append(
        AutomationProposal(
          id: proposalId, runId: recordId, judge: end.nodeId, defId: end.defId, row: proposal.row,
          originNodeId: originNodeId, fields: proposal.fields, title: proposal.title,
          due: proposal.due, workspace: proposal.workspace, reason: proposal.reason,
          proposedAt: endedAt, state: .open))
    }
    for open in reconciled.resolving {
      try db.resolve(memory.proposals[open].id, at: endedAt)
      memory.proposals[open].state = .resolved
    }
  }

  /// 外した最初の回なら印を書き、ノードの状態を読み直し、忘れる候補を忘れ、数え直す。
  private func finish(run recordId: Int, endedAt: Date, _ memory: inout AutomationMemory) throws {
    if end.outcome.breach != nil, memory.automations[index].state(end.nodeId).breach == nil {
      try db.setBreach(end.nodeId, run: recordId)
    }
    try memory.reread(end.nodeId, of: end.automationId, db)
    try memory.forgetUnheld(db, now: endedAt)
    try memory.recount(
      end.automationId, db, now: endedAt,
      nodeIds: [end.nodeId] + memory.automations[index].graph.downstream(of: end.nodeId).map(\.id))
  }
}
