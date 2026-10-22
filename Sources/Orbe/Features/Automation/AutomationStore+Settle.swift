import Foundation

/// 部品の 1 回の確定の中身（`AutomationStore.record` のトランザクションの中）。
struct AutomationSettling {
  let end: AutomationPassEnd
  let node: AutomationGraph.Node
  /// 自動化のメモリの位置。
  let index: Int
  let db: AutomationDatabase
  /// 回の履歴から数えられない捨てた数（持ち越し・読む前に期限で消えた数）。
  private var carried = AutomationDrops()
  private var written = AutomationDatabase.Written()
  private var outputs: [AutomationDatabase.Output] = []

  init(end: AutomationPassEnd, node: AutomationGraph.Node, index: Int, db: AutomationDatabase) {
    self.end = end
    self.node = node
    self.index = index
    self.db = db
  }

  /// 確定する。成功した回は読んだ位置を進めて持ち越しを載せ、役割ごとの結果を書く。どちらの回も記録・回の履歴・外した印を書く。
  mutating func settle(_ run: AutomationPartRun, _ memory: inout AutomationMemory) throws
    -> AutomationRecorded
  {
    var run = run
    var judged: (proposals: [AutomationPartPass.Proposal], resolved: [String])?
    if !run.failed, case .succeeded(let output, _, _) = end.outcome {
      try consume()
      switch output {
      case .judge(let proposals, let resolved): judged = (proposals, resolved)
      default: try produce(output, &run, &memory)
      }
    }
    var dropped = carried
    for drop in end.read?.dropped ?? [] { dropped.add(.init(drop.reason)) }
    run.dropped = dropped
    let decided = judged.map { decide($0.proposals, $0.resolved, memory) }
    if let decided {
      run.result = .judge(
        proposed: decided.pending.count, resolved: decided.resolving.count,
        dismissed: decided.dismissed)
    }
    let recordId = try db.insert(
      run: run, of: end.part, defId: end.defId, carried: run.failed ? AutomationDrops() : carried)
    if let read = end.read {
      try db.insertInputs(
        of: recordId,
        read.taken.map { ($0.ref, "taken") } + read.dropped.map { ($0.row.ref, $0.reason.how) })
    }
    if let decided { try apply(decided, run: recordId, &memory) }
    try finish(AutomationRunRecord(id: recordId, defId: end.defId, content: .known(run)), &memory)
    if decided != nil || run.withdrawn != nil {
      try memory.recountJudges(db, now: run.endedAt)
    }
    return AutomationRecorded(changed: written.changed, run: run, outputs: recordedOutputs())
  }

  /// 読んだ位置を進め、持ち越しを回の記録へ移す。
  private mutating func consume() throws {
    guard let read = end.read else { return }
    try db.advance(end.part, read.reach)
    carried.add(try db.pendingDrops(of: end.part))
    carried.add(.lapsed, read.lapsed)
    try db.setPendingDrops(end.part, AutomationDrops())
  }

  /// 判定でない役割の結果。取得・処理は出した行を照らし（今の集合は項目と版、出来事の流れは出来事）、出どころの項目が無効に
  /// なった判断待ちの候補を下げる（下げた数は取得の回にだけ数える）。
  private mutating func produce(
    _ output: AutomationPartPass.Output, _ run: inout AutomationPartRun,
    _ memory: inout AutomationMemory
  ) throws {
    switch output {
    case .fetch(let rows), .process(let rows):
      outputs = rows.map { AutomationDatabase.Output(id: $0.id, body: $0.text, source: $0.source) }
      written =
        node.coverage == .currentSet
        ? try db.writeItems(of: end.part, outputs, at: run.endedAt, replacing: !end.given)
        : try db.writeEvents(of: end.part, outputs, at: run.endedAt, distinct: !end.given)
      let withdrawn = try memory.withdraw(originatingIn: written.invalidated, db)
      if node.role == .fetch {
        run.result = .fetch(fresh: written.fresh.count, duplicates: written.duplicates)
        run.withdrawn = withdrawn
      } else {
        run.result = .process(fresh: written.fresh.count, duplicates: written.duplicates)
      }
    case .report(let text): run.result = .report(text: text)
    case .work(.done(let text)): run.result = .work(text: text, nothing: nil)
    case .work(.nothing(let reason)): run.result = .work(text: nil, nothing: reason)
    case .sideEffect: run.result = .sideEffect(count: run.execution.count)
    case .judge: break
    }
  }

  /// 判定の出力をこの時点の候補に当て直したもの。
  private struct Decided {
    let pending: [AutomationPartPass.Proposal]
    let resolving: [Int]
    let dismissed: [AutomationDismissal]
  }

  /// 回の途中に他の確定や人のさばきがあっても、既に候補のあるリンクへの案は理由付きで捨て、判断待ちでない候補は対応済みに
  /// しない。
  private func decide(
    _ proposals: [AutomationPartPass.Proposal], _ resolved: [String], _ memory: AutomationMemory
  ) -> Decided {
    var proposed = memory.heldLinks
    var pending: [AutomationPartPass.Proposal] = []
    var resolving: [Int] = []
    var dismissed: [AutomationDismissal] = []
    for proposal in proposals {
      guard proposed.insert(proposal.origin.item.link).inserted else {
        dismissed.append(
          AutomationDismissal(link: proposal.origin.item.link, why: .alreadyProposed))
        continue
      }
      pending.append(proposal)
    }
    for link in resolved {
      guard
        let open = memory.proposals.firstIndex(where: { $0.item.link == link && $0.state == .open }
        ),
        !resolving.contains(open)
      else {
        dismissed.append(AutomationDismissal(link: link, why: .noOpenProposal))
        continue
      }
      resolving.append(open)
    }
    return Decided(pending: pending, resolving: resolving, dismissed: dismissed)
  }

  /// 候補を足し（判定の回を指し、覚えている印を付ける）、対応済みにする。
  private func apply(_ decided: Decided, run recordId: Int, _ memory: inout AutomationMemory)
    throws
  {
    let endedAt = TaskItem.storedInstant(end.endedAt)
    for proposal in decided.pending {
      let proposalId = try db.insert(proposal: proposal, run: recordId)
      memory.proposals.append(
        AutomationProposal(
          id: proposalId, runId: recordId, automationId: end.automationId, judge: end.part,
          defId: end.defId, source: proposal.origin.part, origin: proposal.origin.row,
          item: proposal.origin.item, title: proposal.title, due: proposal.due,
          workspace: proposal.workspace, reason: proposal.reason, proposedAt: endedAt,
          state: .open))
    }
    for open in decided.resolving {
      try db.resolve(memory.proposals[open].id, at: endedAt)
      memory.proposals[open].state = .resolved
    }
  }

  /// 外した最初の回なら印を書き、部品の状態を読み直し、忘れる候補を忘れ、数え直す。
  private func finish(_ entry: AutomationRunRecord, _ memory: inout AutomationMemory) throws {
    if end.outcome.breach != nil, memory.automations[index].state(end.part).breach == nil {
      try db.setBreach(end.part, run: entry.id)
    }
    try memory.reread(end.part, of: end.automationId, db)
    try memory.forgetUnheld(db)
    try memory.recount(
      end.automationId, db, now: entry.endedAt,
      parts: [end.part] + memory.automations[index].graph.downstream(of: end.part).map(\.id))
  }

  /// 出した行ごとの、今それを表す行と下流へ渡す 1 行。
  private func recordedOutputs() -> [AutomationRecorded.Output] {
    let fresh = Set(written.fresh)
    return zip(written.rows, outputs).enumerated().compactMap { index, pair in
      guard let ref = pair.0 else { return nil }
      let output = pair.1
      let downstream = output.source == nil ? "\(end.part):\(output.id)" : output.id
      return AutomationRecorded.Output(
        ref: ref, text: AutomationPrompts.replacing(id: downstream, in: output.body),
        fresh: fresh.contains(index))
    }
  }
}
