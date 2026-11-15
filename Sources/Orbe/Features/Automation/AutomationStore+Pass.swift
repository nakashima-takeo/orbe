import Foundation

/// ノードの 1 回の終わり。走らせ役が組み、ストアが確定（または失敗の記録）にする。
struct AutomationPassEnd {
  let automationId: Int
  let nodeId: AutomationNodeID
  /// 回が動いた定義（回を始めた時点のノードの定義）。
  let defId: AutomationNodeDefID
  let trigger: AutomationNodeRun.Trigger
  let startedAt: Date
  let endedAt: Date
  /// 読んだもの。入力の無いノードは nil。
  let read: AutomationIntake.Read?
  let outcome: AutomationNodePass.Outcome
}

/// 確定したノードの 1 回。
struct AutomationRecorded {
  /// 出す側の行が変わった（下流の受け手に起こす決まりを見る）。
  let changed: Bool
  /// 書いた回の記録。自動化かノードがもう無く、何も書かなかったなら nil。
  let run: AutomationNodeRun?
  /// 判定の回が確定で足した候補と対応済みにした候補（当て直して捨てた案を除く）。成功した判定の回でなければ nil。
  let judged: AutomationJudged?
}

/// 判定の回が確定で候補に掛けたもの。
struct AutomationJudged: Equatable {
  /// 足した候補の案（案の順）。
  let proposals: [AutomationNodePass.Proposal]
  /// 対応済みにした候補のリンク（案の順）。
  let resolved: [String]
}

/// ノードの 1 回の読み書き。読みは受け手の取り方（`AutomationIntake`）を通し、行の本文は DB にだけ置く。
extension AutomationStore {
  /// 受け手 `nodeId` の読み。`baseline` はつながりごとの読む上限の番号（契機の始まりの時点の上流の最後の番号）。
  func read(
    _ nodeId: AutomationNodeID, of id: Int, baseline: [AutomationNodeID: AutomationSeqs]?,
    now: Date
  ) throws(AutomationError) -> AutomationIntake.Read? {
    guard let node = automation(id)?.graph.node(nodeId), !node.inputs.isEmpty else { return nil }
    let closed = memory.closedLinks(of: nodeId)
    return try read {
      try $0.read(
        node, baseline: baseline, context: AutomationIntake.Context(closed: closed, now: now))
    }
  }

  /// 受け手 `nodeId` のつながりごとの読んだ位置と上流の最後の番号（起こす決まりが読む）。
  func positions(of nodeId: AutomationNodeID) throws(AutomationError)
    -> [AutomationNodeID: AutomationDatabase.Position]
  {
    try read { try $0.positions(of: nodeId) }
  }

  /// 取る行が 0 件だった契機を終える。手段を起こさず、回の記録も残さない。受け手として、読んだ位置を、読む上限の番号まで進め、
  /// 捨てた数と読む前に期限で消えた数を持ち越しに足す（次の成功した回の記録に載る）。今の集合の処理なら、出す側として空の結果を
  /// 確定と同じく自分の項目に照らす（今有効な項目はすべて無効になる）。この照らしは、進める位置が無い契機でも行う——予定・手動で
  /// 回る処理と流しが起こした処理は、入力を付け替えた直後で、新しい上流がまだ 1 行も出していなくても、この契機を迎える。「届いたら」
  /// の処理は上流の番号が進まないと起きないので、付け替えた直後のこの契機は迎えない。出す側の行が変わったかを返す（変わったら
  /// 走らせ役が下流の起こす決まりを見る）。
  @discardableResult func endEmptyTrigger(
    _ read: AutomationIntake.Read, of nodeId: AutomationNodeID, in id: Int, now: Date
  ) throws(AutomationError) -> Bool {
    guard read.taken.isEmpty, let graph = automation(id)?.graph, let node = graph.node(nodeId)
    else { return false }
    let producing = node.role == .process && node.coverage == .currentSet
    guard producing || !read.reach.isEmpty else { return false }
    let at = TaskItem.storedInstant(now)
    return try commit(sweepingAt: at) { db, memory in
      if !read.reach.isEmpty {
        try db.advance(nodeId, read.reach)
        var carried = try db.carried(of: nodeId)
        for drop in read.dropped { carried.dropped.add(drop.reason) }
        carried.dropped.add(.lapsed, read.lapsed)
        try db.setCarried(nodeId, carried)
      }
      var changed = false
      if producing { changed = try db.writeItems(of: nodeId, [], at: at).changed }
      try memory.recount(
        id, db, now: now,
        nodeIds: [nodeId] + (changed ? graph.downstream(of: nodeId).map(\.id) : []))
      return changed
    }
  }

  /// ノードの 1 回を 1 トランザクションで確定する。
  ///
  /// 成功した回は、読んだ位置を進め、持ち越しを記録に載せて空に戻し、出す側なら出した行を照らし（今の集合は項目と版、出来事の
  /// 流れは出来事）、書いた直後に判断待ちの候補へ下げる条件を当てる。判定なら候補を足し・対応済みにする。失敗した回は記録・
  /// 回の履歴・形式エラーの印だけを書き、出す側の行・読んだ位置・持ち越しは動かさない——失敗を「0 件取れた」と読み違えて候補を一斉に
  /// 下げないため。どちらも回の履歴（読んだ行と扱い）を書き、出力が決まりを外した最初の回なら印を書く。自動化かノードがもう
  /// 無ければ何もしない。
  func record(_ end: AutomationPassEnd) throws(AutomationError) -> AutomationRecorded {
    guard let index = automations.firstIndex(where: { $0.id == end.automationId }),
      let node = automations[index].graph.node(end.nodeId)
    else { return AutomationRecorded(changed: false, run: nil, judged: nil) }
    var run = AutomationNodeRun(
      startedAt: TaskItem.storedInstant(end.startedAt),
      endedAt: TaskItem.storedInstant(end.endedAt), trigger: end.trigger,
      taken: end.read?.taken.count, execution: end.outcome.execution,
      breach: end.outcome.breach)
    if case .failed(let reason, _, _) = end.outcome { run.failure = reason }
    return try commit(sweepingAt: run.endedAt) { db, memory in
      var recording = AutomationRecording(end: end, node: node, index: index, db: db)
      return try recording.record(run, &memory)
    }
  }
}

extension AutomationStore {
  /// 数えた行のどれかが古さの上限か出来事の残す期間を過ぎる最も早い時刻（どの受け手でも）。
  var nextPendingExpiry: Date? {
    automations.flatMap { $0.states.values.compactMap(\.pending.expiresAt) }.min()
  }

  /// `now` が、数えた行が古さの上限か出来事の残す期間を過ぎる時刻より後になった受け手の「読めば取る行」の数を数え直す。
  func recountExpired(now: Date) throws(AutomationError) {
    let expired = automations.map { automation in
      (
        automation.id,
        automation.states.filter { ($0.value.pending.expiresAt ?? .distantFuture) < now }.map(\.key)
      )
    }.filter { !$0.1.isEmpty }
    guard !expired.isEmpty else { return }
    try commit(sweepingAt: nil) { db, memory in
      for (id, nodeIds) in expired { try memory.recount(id, db, now: now, nodeIds: nodeIds) }
    }
  }

  /// すべての受け手の「読めば取る行」の数を数え直す（保持の設定が変わったとき。出来事の残す期間の既定が変わりうる）。
  func recountAll(now: Date) throws(AutomationError) {
    let ids = automations.map(\.id)
    guard !ids.isEmpty else { return }
    try commit(sweepingAt: nil) { db, memory in
      for id in ids { try memory.recount(id, db, now: now) }
    }
  }
}

extension AutomationMemory {
  /// 受け手の「読めば取る行」を数え直す。`nodeIds` を省けば自動化の入力のあるノードすべて。起動時も変化の後も、これだけが数える。
  mutating func recount(
    _ id: Int, _ db: AutomationDatabase, now: Date, nodeIds: [AutomationNodeID]? = nil
  ) throws {
    guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
    let automation = automations[index]
    for node in automation.graph.nodes
    where !node.inputs.isEmpty && (nodeIds?.contains(node.id) ?? true) {
      let closed = closedLinks(of: node.id)
      automations[index].states[node.id]?.pending = try db.pending(node, closed: closed, now: now)
    }
  }

  /// 判定のノード `judges` の数を数え直す（判断待ちでない覚えている候補のリンクが変わると、判定の前に捨てる行が変わる）。
  mutating func recountJudges(_ judges: Set<AutomationNodeID>, _ db: AutomationDatabase, now: Date)
    throws
  {
    guard !judges.isEmpty else { return }
    for automation in automations {
      let nodeIds = automation.graph.judges.map(\.id).filter(judges.contains)
      guard !nodeIds.isEmpty else { continue }
      try recount(automation.id, db, now: now, nodeIds: nodeIds)
    }
  }
}
