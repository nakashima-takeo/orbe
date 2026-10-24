import Foundation

/// 回の記録の読み書き。時刻・契機・失敗は列に、回の履歴から数えられない残りは JSON に持ち、取った数と読んで捨てた数は読むときに
/// 回の履歴から組む。回の記録の中身を組むのは読みのここだけで、確定も書いた記録を読み直して返す。
extension AutomationDatabase {
  /// 回の記録を足して ID を返す。`carried` は回の履歴から数えられない捨てた数（持ち越し・読む前に期限で消えた数）。
  func insert(
    run: AutomationNodeRun, of nodeId: AutomationNodeID, defId: AutomationNodeDefID,
    carried: AutomationDrops
  ) throws -> Int {
    try db.run(
      """
      INSERT INTO runs (node_id, def_id, started_at, ended_at, trigger, failure, record)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .integer(Int64(nodeId.rawValue)), .integer(Int64(defId.rawValue)),
        Self.instant(run.startedAt), Self.instant(run.endedAt), .text(run.trigger.rawValue),
        try run.failure.map { .text(try Self.encode($0)) } ?? .null,
        .text(try Self.encode(AutomationRunStore(run, carried: carried))),
      ])
    return Int(db.lastInsertRowID)
  }

  /// `nodeIds` の回の記録を混ぜて新しい順に `limit` 件（`before` より前の ID だけ）。それぞれにノードの今の鍵を添える。
  func records(of nodeIds: [AutomationNodeID], before: Int? = nil, limit: Int) throws
    -> [AutomationKeyedRecord]
  {
    let list = nodeIds.map { String($0.rawValue) }.joined(separator: ",")
    return try selectRecords(
      "WHERE r.node_id IN (\(list)) AND r.id < ? ORDER BY r.id DESC LIMIT ?",
      [.integer(Int64(before ?? Int.max)), .integer(Int64(limit))])
  }

  /// 最新の成功した回の開始時刻。
  func succeededAt(of nodeId: AutomationNodeID) throws -> Date? {
    try db.select(
      "SELECT started_at FROM runs WHERE node_id = ? AND failure IS NULL ORDER BY id DESC LIMIT 1",
      [.integer(Int64(nodeId.rawValue))]
    ) { AutomationPersistence.date($0.int64(at: 0)) }.first
  }

  /// 外した印の回の記録。
  func breachRecord(of nodeId: AutomationNodeID) throws -> AutomationRunRecord? {
    try selectRecords(
      "WHERE r.id = (SELECT breach_run_id FROM nodes WHERE id = ?)",
      [.integer(Int64(nodeId.rawValue))]
    ).first?.record
  }

  /// 回の記録を 1 つの問い合わせで読み、回の履歴の数をもう 1 つの問い合わせでまとめて引く。
  private func selectRecords(_ clause: String, _ values: [SQLiteValue]) throws
    -> [AutomationKeyedRecord]
  {
    let rows = try db.select(
      """
      SELECT r.id, n.key, r.started_at, r.ended_at, r.trigger, r.failure, r.record
      FROM runs r JOIN nodes n ON n.id = r.node_id \(clause)
      """, values
    ) { s in
      (
        id: s.int(at: 0), key: s.text(at: 1) ?? "",
        started: AutomationPersistence.date(s.int64(at: 2)),
        ended: AutomationPersistence.date(s.int64(at: 3)),
        trigger: AutomationNodeRun.Trigger(rawValue: s.text(at: 4) ?? "") ?? .schedule,
        failure: s.text(at: 5), record: s.text(at: 6)
      )
    }
    let inputs = try self.inputs(of: rows.map(\.id))
    return rows.map { row in
      AutomationKeyedRecord(
        nodeKey: row.key,
        record: AutomationRunRecord(
          id: row.id,
          content: Self.content(
            AutomationUnknownRun(
              startedAt: row.started, endedAt: row.ended, trigger: row.trigger,
              failed: row.failure != nil),
            failure: row.failure, record: row.record, inputs: inputs[row.id] ?? [:])))
    }
  }

  /// 列（`columns`）と保存の JSON と回の履歴の数から組んだ中身。どれかが読めなければ列から分かる分だけの不明な記録。
  private static func content(
    _ columns: AutomationUnknownRun, failure rawFailure: String?, record: String?,
    inputs: [String: Int]
  ) -> AutomationRunRecord.Content {
    let unknown = AutomationRunRecord.Content.unknown(columns)
    var failure: AutomationFailure?
    if let rawFailure {
      guard let decoded = decode(AutomationFailure.self, rawFailure) else { return unknown }
      failure = decoded
    }
    guard let stored = decode(AutomationRunStore.self, record) else { return unknown }
    var dropped = stored.carried
    for (how, count) in inputs where how != "taken" {
      guard let reason = AutomationDrops.Reason(rawValue: how) else { return unknown }
      dropped.add(reason, count)
    }
    return .known(
      AutomationNodeRun(
        startedAt: columns.startedAt, endedAt: columns.endedAt, trigger: columns.trigger,
        taken: stored.reads ? inputs["taken"] ?? 0 : nil, dropped: dropped,
        execution: stored.execution,
        breach: stored.breach, result: stored.result, withdrawn: stored.withdrawn,
        failure: failure))
  }

  /// 回ごとの、回の履歴を扱いごとに数えたもの。
  private func inputs(of runs: [Int]) throws -> [Int: [String: Int]] {
    guard !runs.isEmpty else { return [:] }
    let list = runs.map(String.init).joined(separator: ",")
    var counts: [Int: [String: Int]] = [:]
    for (run, how, count) in try db.select(
      """
      SELECT run_id, how, count(*) FROM run_item_inputs WHERE run_id IN (\(list)) GROUP BY run_id, how
      UNION ALL
      SELECT run_id, how, count(*) FROM run_event_inputs WHERE run_id IN (\(list)) GROUP BY run_id, how
      """, [], { ($0.int(at: 0), $0.text(at: 1) ?? "", $0.int(at: 2)) })
    {
      counts[run, default: [:]][how, default: 0] += count
    }
    return counts
  }
}

/// 回の記録 1 件と、それを持つノードの今の鍵。
struct AutomationKeyedRecord: Equatable {
  let nodeKey: String
  let record: AutomationRunRecord
}
