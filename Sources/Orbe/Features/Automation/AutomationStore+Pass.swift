import Foundation

/// 部品の 1 回の終わり。走らせ役が組み、ストアが確定（または失敗の記録）にする。
struct AutomationPassEnd {
  let automationId: Int
  let part: AutomationPartID
  /// 回が動いた定義（回を始めた時点の部品の定義）。
  let defId: AutomationDefID
  let trigger: AutomationPartRun.Trigger
  let startedAt: Date
  let endedAt: Date
  /// 読んだもの。入力の無い部品は nil。
  let read: AutomationInbox.Read?
  let outcome: AutomationPartPass.Outcome

  /// 試走の与えた行を出力にした取得の回（今の集合でも他の項目を無効にせず、出来事の見分けも掛けない）。
  var given: Bool { outcome.execution.ending == .givenToTrial }
}

/// 確定した部品の 1 回。
struct AutomationRecorded {
  /// 出す側の行が変わった（下流の受け手に起こす決まりを見る）。
  let changed: Bool
  /// 書いた回の記録。自動化か部品がもう無く、何も書かなかったなら nil。
  let run: AutomationPartRun?
  /// 出した行ごとの、今それを表す行と下流へ渡す 1 行（出力の順。足さなかった重なりは除く）。試走が添える。
  var outputs: [Output] = []

  struct Output: Equatable {
    let ref: AutomationRowRef
    let text: String
    /// この回が新しく有効にした行か。
    let fresh: Bool
  }

  /// 失敗した回として書いたか（部品の 1 回が成功していても、確定で失敗にした回を含む）。
  var failed: Bool { run?.failed ?? false }
}

/// 部品の 1 回の読み書き。読みは受け手の取り方（`AutomationInbox`）を通し、行の本文は DB にだけ置く。
extension AutomationStore {
  /// 受け手 `part` の読み。`baseline` はつながりごとの読む上限の番号（契機の始まりの時点の上流の最後の番号）。
  func read(
    _ part: AutomationPartID, of id: Int, baseline: [AutomationPartID: (item: Int, event: Int)]?,
    now: Date, overrides: [AutomationReadOverride] = []
  ) throws(AutomationError) -> AutomationInbox.Read? {
    guard let automation = automation(id), let node = automation.graph.node(part),
      !node.inputs.isEmpty
    else { return nil }
    let links = heldLinks
    return try read {
      try $0.read(
        node, in: automation.graph, baseline: baseline,
        context: AutomationInbox.Context(proposed: links.contains, now: now, batch: true),
        overrides: overrides)
    }
  }

  /// 取る行が 0 件だった契機。捨てた行があれば読んだ位置をその最大の番号まで進め、捨てた数と読む前に期限で消えた数を受け手の
  /// 部品の持ち越しに足す（次の成功した回の記録に載る）。
  func discard(_ read: AutomationInbox.Read, of part: AutomationPartID, in id: Int, now: Date)
    throws(AutomationError)
  {
    guard read.taken.isEmpty, let index = automations.firstIndex(where: { $0.id == id }),
      automations[index].parts[part] != nil, !read.reach.isEmpty
    else { return }
    try commit(sweepingAt: TaskItem.storedInstant(now)) { db, memory in
      try db.advance(part, read.reach)
      var state = memory.automations[index].state(part)
      for drop in read.dropped { state.pendingDrops.add(.init(drop.reason)) }
      state.pendingDrops.add(.lapsed, read.lapsed)
      try db.setPendingDrops(part, state.pendingDrops)
      memory.automations[index].parts[part] = state
      try memory.refreshReads(id, part, db)
      try memory.recount(id, db, now: now, parts: [part])
    }
  }

  /// 部品の 1 回を 1 トランザクションで確定する。
  ///
  /// 成功した回は、読んだ位置を進め、持ち越しを記録に載せて空に戻し、出す側なら出した行を照らして（今の集合は項目と版、出来事の
  /// 流れは出来事）、判定なら候補を足し・対応済みにする。出どころの項目が無効になった判断待ちの候補を下げる。失敗した回は記録・
  /// 回の履歴・外した印だけを書き、出す側の行・読んだ位置・持ち越しは動かさない——失敗を「0 件取れた」と読み違えて候補を一斉に
  /// 下げないため。どちらも回の履歴（読んだ行と扱い）を書き、出力が決まりを外した最初の回なら印を書く。
  ///
  /// 判定へ届く処理が出した行が 1 行以上あって、どれも出どころを持たず、そのうちに部品が自分で作った行（入力を引き継がない行）
  /// があれば、成功した回も失敗した回として書く——回の途中に判定の部品を下流に足す書き換えがあると、始めた時点では判定へ届か
  /// なかった部品の出力がそうなりうる。自動化か部品がもう無ければ何もしない。
  func record(_ end: AutomationPassEnd) throws(AutomationError) -> AutomationRecorded {
    guard let index = automations.firstIndex(where: { $0.id == end.automationId }),
      let node = automations[index].graph.node(end.part)
    else { return AutomationRecorded(changed: false, run: nil) }
    var run = AutomationPartRun(
      startedAt: TaskItem.storedInstant(end.startedAt),
      endedAt: TaskItem.storedInstant(end.endedAt), trigger: end.trigger,
      taken: end.read?.taken.count, execution: end.outcome.execution,
      breach: end.outcome.breach.map(AutomationPartRun.Breach.init))
    if case .succeeded(.process(let rows), _, _) = end.outcome,
      let judge = automations[index].graph.judges(reachedFrom: node.id).first, !rows.isEmpty,
      rows.allSatisfy({ $0.origin == nil }), rows.contains(where: { $0.source == nil })
    {
      run.failure = .unsourced(judge.key)
    } else if case .failed(let reason, _, _) = end.outcome {
      run.failure = reason
    }
    return try commit(sweepingAt: run.endedAt) { db, memory in
      var settling = AutomationSettling(
        end: end, node: node, index: index, db: db, state: memory.automations[index].state(end.part)
      )
      return try settling.settle(run, &memory)
    }
  }

  /// 試走で入力のある入口に与えた行を、上流 `part` の出力として足す（今の集合でも他の項目を無効にせず、出来事の流れでも見分けを
  /// 掛けない）。足した行の参照を返す。
  func give(_ rows: [AutomationPartRow], as part: AutomationPartID, of id: Int, at: Date)
    throws(AutomationError) -> Set<AutomationRowRef>
  {
    let index = try index(id)
    guard let node = automations[index].graph.node(part) else {
      throw .partNotFound(id, "\(part)")
    }
    let at = TaskItem.storedInstant(at)
    return try commit(sweepingAt: nil) { db, memory in
      let outputs = rows.map { AutomationDatabase.Output(id: $0.id, body: $0.text, source: nil) }
      let written =
        node.coverage == .currentSet
        ? try db.writeItems(of: part, outputs, at: at, replacing: false)
        : try db.writeEvents(of: part, outputs, at: at, distinct: false)
      var state = memory.automations[index].state(part)
      let seqs = try db.lastSeqs(of: part)
      state.lastItemSeq = seqs.item
      state.lastEventSeq = seqs.event
      state.changes += 1
      memory.automations[index].parts[part] = state
      try memory.recount(id, db, now: at)
      return Set(written.rows.compactMap { $0 })
    }
  }
}

extension AutomationStore {
  /// 数えた行のどれかが古さの上限を過ぎる最も早い時刻（どの受け手でも）。
  var nextInboxExpiry: Date? {
    automations.flatMap { $0.parts.values.compactMap(\.inboxExpiresAt) }.min()
  }

  /// 数えた行が古さの上限を過ぎた（`now` が過ぎる時刻より後の）受け手の「読めば取る行」の数を数え直す。
  func recountExpired(now: Date) throws(AutomationError) {
    let expired = automations.map { automation in
      (
        automation.id,
        automation.parts.filter { ($0.value.inboxExpiresAt ?? .distantFuture) < now }.map(\.key)
      )
    }.filter { !$0.1.isEmpty }
    guard !expired.isEmpty else { return }
    try commit(sweepingAt: nil) { db, memory in
      for (id, parts) in expired { try memory.recount(id, db, now: now, parts: parts) }
    }
  }
}

extension AutomationMemory {
  /// 受け手の読んだ位置を DB から写す。
  mutating func refreshReads(_ id: Int, _ part: AutomationPartID, _ db: AutomationDatabase) throws {
    guard let index = automations.firstIndex(where: { $0.id == id }),
      let node = automations[index].graph.node(part)
    else { return }
    automations[index].parts[part]?.reads = try db.readings(of: node).mapValues {
      AutomationReadPosition(item: $0.item, event: $0.event)
    }
  }

  /// 受け手の「読めば取る行」の数を数え直す。`parts` を省けば自動化の入力のある部品すべて。
  mutating func recount(
    _ id: Int, _ db: AutomationDatabase, now: Date, parts: [AutomationPartID]? = nil
  ) throws {
    guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
    let automation = automations[index]
    let links = heldLinks
    for node in automation.graph.nodes
    where !node.inputs.isEmpty && (parts?.contains(node.id) ?? true) {
      let pending = try db.pending(node, in: automation.graph, proposed: links.contains, now: now)
      automations[index].parts[node.id]?.inbox = pending.count
      automations[index].parts[node.id]?.inboxExpiresAt = pending.expiresAt
    }
  }

  /// 判定の部品の数を数え直す（覚えている候補が変わると「既に候補がある」で捨てる行が変わる）。
  mutating func recountJudges(_ db: AutomationDatabase, now: Date) throws {
    for automation in automations where automation.judges {
      try recount(automation.id, db, now: now, parts: automation.graph.judges.map(\.id))
    }
  }
}
