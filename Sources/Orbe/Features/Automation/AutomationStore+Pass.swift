import Foundation

/// 部品の 1 回の終わり。走らせ役が組み、ストアが確定（または失敗の記録）にする。
struct AutomationPassEnd {
  let automationId: Int
  let part: String
  let trigger: AutomationPartRun.Trigger
  let startedAt: Date
  let endedAt: Date
  /// 溜まりから取ったもの。入力の無い部品は nil。
  let take: AutomationInbox.Take?
  let outcome: AutomationPartPass.Outcome
}

/// 確定した部品の 1 回。
struct AutomationRecorded {
  /// 溜まりが増えた下流の部品の鍵。
  let grew: [String]
  /// 失敗した回として書いたか（部品の 1 回が成功していても、確定で失敗にした回を含む）。
  let failed: Bool
}

/// 部品の 1 回の読み書き。取る・積むは溜まりの規則（`AutomationInbox`）を通し、行の本文は DB にだけ置く。
extension AutomationStore {
  /// 溜まりの目録（本文なし、通し番号の順）。
  func inbox(of key: String, in id: Int) throws(AutomationError) -> [AutomationInbox.Row] {
    try read { try $0.inbox(of: key, in: id) }
  }

  /// 取った行の本文（通し番号の順）。読む前に消えていた行は飛ばす。
  func rows(_ seqs: [Int]) throws(AutomationError) -> [AutomationPartRow] {
    try read { try $0.rows(seqs) }
  }

  /// 取る行が 0 件だった契機で、捨てる行を消して部品の捨てた数に足す（次の回の記録に数える）。
  func discard(_ drops: [AutomationInbox.Drop], of key: String, in id: Int)
    throws(AutomationError)
  {
    guard !drops.isEmpty, let index = automations.firstIndex(where: { $0.id == id }),
      automations[index].parts[key] != nil
    else { return }
    try commit { db, memory in
      try db.delete(inbox: drops.map(\.seq))
      var state = memory.automations[index].state(key)
      for drop in drops { state.pendingDrops.add(.init(drop.reason)) }
      (state.inbox, state.newestSeq) = try db.inboxCount(of: key, in: id)
      try db.put(part: key, of: id, state)
      memory.automations[index].parts[key] = state
    }
  }

  /// 部品の 1 回を 1 トランザクションで確定する。成功した回は、取った行と捨てた行を通し番号で消し、下流の溜まりへ積み、前回の
  /// 出力と目印・候補の帳面・回の記録を書く。失敗した回は記録と最後に回った時刻だけを書き、溜まり・前回の出力・捨てた数は
  /// 動かさない。下流の判定の部品へ渡す行が 1 行以上あって、どれも出どころを持たず、そのうちに部品が自分で作った行（取った
  /// 行の `id` でない行）があれば、成功した回も失敗した回として書く——回の途中に判定の部品を下流に足す書き換えがあると、始めた
  /// 時点では判定へ届かなかった部品の出力がそうなりうる（次の回は判定へ届くものとして読まれ、作った行は決まりを外した行に
  /// なる）。取った行を素通ししただけで出どころが無いなら部品の誤りではないので、確定して判定へは積まずに捨てる（失敗に
  /// すると、出どころを得られない同じ行で失敗を繰り返す）。どちらも、出力が決まりを外した最初の回なら印を書く。自動化か部品が
  /// もう無ければ何もしない。
  func record(_ end: AutomationPassEnd) throws(AutomationError) -> AutomationRecorded {
    guard let index = automations.firstIndex(where: { $0.id == end.automationId }),
      let node = automations[index].graph.node(end.part)
    else { return AutomationRecorded(grew: [], failed: false) }
    let id = end.automationId
    let key = end.part
    let startedAt = TaskItem.storedInstant(end.startedAt)
    let endedAt = TaskItem.storedInstant(end.endedAt)
    var run = AutomationPartRun(
      startedAt: startedAt, endedAt: endedAt, trigger: end.trigger, taken: end.take?.taken.count,
      execution: end.outcome.execution,
      breach: end.outcome.breach.map(AutomationPartRun.Breach.init)
    )
    return try commit { db, memory in
      var grew: [String] = []
      let planned = try pushes(of: end.outcome, from: node, index, memory, db)
      let taken = Set(end.take?.taken ?? [])
      let inputIds = Set(try db.inbox(of: key, in: id).filter { taken.contains($0.seq) }.map(\.id))
      if let refused = planned.first(where: { entry in
        entry.push.upstreamFailed && entry.push.unsourced.contains { !inputIds.contains($0.id) }
      }) {
        run.failure =
          "no row passed to part \"\(refused.target.key)\" has an origin (it did not come from a "
          + "fetch part)"
      } else if case .succeeded(let output, _, _) = end.outcome {
        var state = memory.automations[index].state(key)
        for drop in end.take?.dropped ?? [] { run.dropped.add(.init(drop.reason)) }
        run.dropped.add(state.pendingDrops)
        state.pendingDrops = AutomationDrops()
        state.succeededAt = startedAt
        if let take = end.take {
          try db.delete(inbox: take.taken + take.dropped.map(\.seq))
          (state.inbox, state.newestSeq) = try db.inboxCount(of: key, in: id)
        }
        if case .fetch(_, let lastOutput) = output { state.lastOutput = lastOutput }
        memory.automations[index].parts[key] = state
        grew = try settle(
          output, &run, Settling(node: node, index: index, db: db, pushes: planned), &memory)
      } else if case .failed(let reason, _, _) = end.outcome {
        run.failure = reason
      }
      var state = memory.automations[index].state(key)
      if let breach = end.outcome.breach, state.breach == nil {
        state.breach = AutomationBreachMark(
          at: startedAt, lines: AutomationRejections(breach.lines), redone: breach.redo != nil,
          passed: !run.failed)
      }
      state.lastRunAt = startedAt
      state.runs.insert(run, at: 0)
      state.runs = Array(state.runs.prefix(AutomationPartState.retainedRuns))
      try db.put(part: key, of: id, state)
      try db.insert(run: run, part: key, of: id)
      memory.automations[index].parts[key] = state
      return AutomationRecorded(grew: grew, failed: run.failed)
    }
  }

  /// 役割ごとの確定。行は下流へ積み、判定は候補の帳面に当て直す。取得と判定の確定は候補の持ち主を決め直し、下げた数は取得の
  /// 回の記録にだけ数える。
  private func settle(
    _ output: AutomationPartPass.Output, _ run: inout AutomationPartRun, _ settling: Settling,
    _ memory: inout AutomationMemory
  ) throws -> [String] {
    switch output {
    case .fetch(let rows, _):
      let (stacked, grew) = try stack(settling, at: run.endedAt, &memory)
      run.result = .fetch(fresh: rows.count)
      run.stacked = stacked
      run.withdrawn = try memory.forgetUnheld(settling.db)
      return grew
    case .process:
      let (stacked, grew) = try stack(settling, at: run.endedAt, &memory)
      run.result = .process
      run.stacked = stacked
      return grew
    case .judge(let proposals, let resolved):
      run.result = try judge(proposals, resolved, settling, at: run.endedAt, &memory)
      try memory.forgetUnheld(settling.db)
    case .report(let text):
      run.result = .report(text: text)
    case .work(.done(let text)):
      run.result = .work(text: text, nothing: nil)
    case .work(.nothing(let reason)):
      run.result = .work(text: nil, nothing: reason)
    case .sideEffect:
      run.result = .sideEffect(count: run.execution.count)
    }
    return []
  }

  /// 成功した回が下流へ渡す行（取得と処理の出力）を、下流の部品ごとに、その時点の溜まりの目録に `AutomationInbox.push` を
  /// 掛けたもの。行を渡さない回は空。
  private func pushes(
    of outcome: AutomationPartPass.Outcome, from node: AutomationGraph.Node, _ index: Int,
    _ memory: AutomationMemory, _ db: AutomationDatabase
  ) throws -> [Push] {
    let rows: [AutomationPartRow]
    switch outcome {
    case .succeeded(.fetch(let fetched, _), _, _): rows = fetched
    case .succeeded(.process(let processed), _, _): rows = processed
    default: return []
    }
    let automation = memory.automations[index]
    let arrivals = rows.map { row in
      AutomationInbox.Arrival(
        id: row.id,
        origin: row.origin.map {
          AutomationInbox.Origin(part: $0.part, item: $0.item.id, link: $0.item.link)
        }, size: row.text.utf8.count)
    }
    return try automation.graph.downstream(of: node.key).map { target in
      Push(
        target: target, rows: rows,
        push: AutomationInbox.push(
          arrivals, into: target, holding: try db.inbox(of: target.key, in: automation.id)))
    }
  }

  /// 積む計算に従って積む。置き換え・件数の上限で消える行は通し番号で消し、積む行は新しい通し番号で足す。件数の上限と、判定の
  /// 部品へ出どころの無いまま届いた行は捨てて、下流の部品の捨てた数に足す（次の回の記録に載る）。積んだ行の数と、溜まりが
  /// 増えた部品を返す。
  private func stack(
    _ settling: Settling, at arrivedAt: Date, _ memory: inout AutomationMemory
  ) throws -> (stacked: Int, grew: [String]) {
    let (node, index, db) = (settling.node, settling.index, settling.db)
    let id = memory.automations[index].id
    var stacked = 0
    var grew: [String] = []
    for entry in settling.pushes {
      let (target, push) = (entry.target, entry.push)
      let byId = Dictionary(entry.rows.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
      try db.delete(inbox: push.replaced + push.overflowed)
      for arrival in push.stacked {
        guard let row = byId[arrival.id] else { continue }
        try db.stack(row, into: target.key, of: id, from: node.key, at: arrivedAt)
      }
      var state = memory.automations[index].state(target.key)
      state.pendingDrops.add(.overflow, push.overflowed.count + push.overflowedArrivals.count)
      state.pendingDrops.add(.unsourced, push.unsourced.count)
      (state.inbox, state.newestSeq) = try db.inboxCount(of: target.key, in: id)
      try db.put(part: target.key, of: id, state)
      memory.automations[index].parts[target.key] = state
      stacked += push.stacked.count
      if !push.stacked.isEmpty { grew.append(target.key) }
    }
    return (stacked, grew)
  }

  /// 判定の出力をこの時点の候補に当て直す。回の途中に他の確定や人のさばきがあっても、既に候補のあるリンクへの案は理由付きで
  /// 捨て、判断待ちでない候補は対応済みにしない。候補の項目は出どころの項目、候補を出した時刻は回の終わり。
  private func judge(
    _ proposals: [AutomationPartPass.Proposal], _ resolved: [String], _ settling: Settling,
    at endedAt: Date, _ memory: inout AutomationMemory
  ) throws -> AutomationPartRun.Result {
    let (node, index, db) = (settling.node, settling.index, settling.db)
    var proposed = 0
    var resolvedCount = 0
    var rejected = AutomationRejections()
    for proposal in proposals {
      let link = proposal.origin.item.link
      guard !memory.proposals.contains(where: { $0.item.link == link }) else {
        rejected.add("propose \(link): already proposed")
        continue
      }
      let draft = AutomationProposal(
        id: 0, automationId: memory.automations[index].id, partKey: node.key,
        sourcePartKey: proposal.origin.part, item: proposal.origin.item, title: proposal.title,
        due: proposal.due, workspace: proposal.workspace, proposedAt: endedAt, state: .open)
      let id = try db.insert(proposal: draft)
      memory.proposals.append(
        AutomationProposal(
          id: id, automationId: draft.automationId, partKey: draft.partKey,
          sourcePartKey: draft.sourcePartKey, item: draft.item, title: draft.title, due: draft.due,
          workspace: draft.workspace, proposedAt: draft.proposedAt, state: .open))
      proposed += 1
    }
    for link in resolved {
      guard
        let open = memory.proposals.firstIndex(where: { $0.item.link == link && $0.state == .open })
      else {
        rejected.add("resolve \(link): no open proposal")
        continue
      }
      memory.proposals[open].state = .resolved
      try db.update(proposal: memory.proposals[open])
      resolvedCount += 1
    }
    return .judge(proposed: proposed, resolved: resolvedCount, rejected: rejected)
  }
}

/// 確定の中で役割ごとの書き込みに運ぶもの（確定する部品・その自動化の位置・トランザクションの中の DB・下流へ積む計算）。
private struct Settling {
  let node: AutomationGraph.Node
  let index: Int
  let db: AutomationDatabase
  let pushes: [Push]
}

/// 下流の部品 1 つへの積む計算と、その元の行。
private struct Push {
  let target: AutomationGraph.Node
  let rows: [AutomationPartRow]
  let push: AutomationInbox.Push
}
