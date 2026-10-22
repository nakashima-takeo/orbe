import Foundation

/// 回の記録の読み書き。時刻・契機・失敗は列に、回の履歴から数えられない残りは JSON に持ち、取った数と読んで捨てた数は読むときに
/// 回の履歴から組む。
extension AutomationDatabase {
  /// 回の記録を足して ID を返す。`carried` は回の履歴から数えられない捨てた数（持ち越し・読む前に期限で消えた数）。
  func insert(
    run: AutomationPartRun, of part: AutomationPartID, defId: AutomationDefID,
    carried: AutomationDrops
  ) throws -> Int {
    try db.run(
      """
      INSERT INTO runs (part_id, def_id, started_at, ended_at, trigger, failure, record)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .integer(Int64(part.rawValue)), .integer(Int64(defId.rawValue)),
        Self.instant(run.startedAt), Self.instant(run.endedAt), .text(run.trigger.rawValue),
        try run.failure.map { .text(try Self.encode($0)) } ?? .null,
        .text(try Self.encode(AutomationRunStore(run, carried: carried))),
      ])
    return Int(db.lastInsertRowID)
  }

  /// 部品の回の記録を新しい順に `limit` 件（`before` より前の ID だけ）。
  func records(of part: AutomationPartID, before: Int? = nil, limit: Int) throws
    -> [AutomationRunRecord]
  {
    try selectRecords(
      "WHERE part_id = ? AND id < ? ORDER BY id DESC LIMIT ?",
      [
        .integer(Int64(part.rawValue)), .integer(Int64(before ?? Int.max)),
        .integer(Int64(limit)),
      ])
  }

  /// `parts` の回の記録を混ぜて新しい順に `limit` 件（`before` より前の ID だけ）。
  func records(among parts: [AutomationPartID], before: Int?, limit: Int) throws
    -> [(part: AutomationPartID, record: AutomationRunRecord)]
  {
    let list = parts.map { String($0.rawValue) }.joined(separator: ",")
    let rows = try db.select(
      "SELECT id, part_id FROM runs WHERE part_id IN (\(list)) AND id < ? ORDER BY id DESC LIMIT ?",
      [.integer(Int64(before ?? Int.max)), .integer(Int64(limit))]
    ) { ($0.int(at: 0), AutomationPartID($0.int(at: 1))) }
    return try rows.compactMap { id, part in
      try selectRecords("WHERE id = ?", [.integer(Int64(id))]).first.map { (part, $0) }
    }
  }

  /// 最新の成功した回の開始時刻。
  func succeededAt(of part: AutomationPartID) throws -> Date? {
    try db.select(
      "SELECT started_at FROM runs WHERE part_id = ? AND failure IS NULL ORDER BY id DESC LIMIT 1",
      [.integer(Int64(part.rawValue))]
    ) { AutomationPersistence.date($0.int64(at: 0)) }.first
  }

  /// 外した印の回の記録。
  func breachRecord(of part: AutomationPartID) throws -> AutomationRunRecord? {
    try selectRecords(
      "WHERE id = (SELECT breach_run_id FROM parts WHERE id = ?)",
      [.integer(Int64(part.rawValue))]
    ).first
  }

  private func selectRecords(_ clause: String, _ values: [SQLiteValue]) throws
    -> [AutomationRunRecord]
  {
    let rows = try db.select(
      "SELECT id, def_id, started_at, ended_at, trigger, failure, record FROM runs \(clause)",
      values
    ) { s in
      (
        id: s.int(at: 0), defId: AutomationDefID(s.int(at: 1)),
        started: AutomationPersistence.date(s.int64(at: 2)),
        ended: AutomationPersistence.date(s.int64(at: 3)),
        trigger: AutomationPartRun.Trigger(rawValue: s.text(at: 4) ?? "") ?? .schedule,
        failure: s.text(at: 5), record: s.text(at: 6)
      )
    }
    return try rows.map { row in
      let unknown = AutomationRunRecord(
        id: row.id, defId: row.defId,
        content: .unknown(
          AutomationUnknownRun(
            startedAt: row.started, endedAt: row.ended, trigger: row.trigger,
            failed: row.failure != nil)))
      var failure: AutomationFailure?
      if let raw = row.failure {
        guard let decoded = Self.decode(AutomationFailure.self, raw) else { return unknown }
        failure = decoded
      }
      guard let stored = Self.decode(AutomationRunStore.self, row.record) else { return unknown }
      let inputs = try self.inputs(of: row.id)
      var dropped = stored.carried
      for (how, count) in inputs where how != "taken" {
        guard let reason = AutomationDrops.Reason(rawValue: how) else { return unknown }
        dropped.add(reason, count)
      }
      let reads: Bool
      switch stored.result {
      case .process, .judge: reads = true
      default: reads = !inputs.isEmpty
      }
      return AutomationRunRecord(
        id: row.id, defId: row.defId,
        content: .known(
          AutomationPartRun(
            startedAt: row.started, endedAt: row.ended, trigger: row.trigger,
            taken: reads ? inputs["taken"] ?? 0 : nil, dropped: dropped,
            execution: stored.execution, breach: stored.breach, result: stored.result,
            withdrawn: stored.withdrawn, failure: failure)))
    }
  }

  /// 回の履歴を扱いごとに数えたもの。
  private func inputs(of run: Int) throws -> [String: Int] {
    var counts: [String: Int] = [:]
    for (how, count) in try db.select(
      """
      SELECT how, count(*) FROM run_item_inputs WHERE run_id = ?1 GROUP BY how
      UNION ALL SELECT how, count(*) FROM run_event_inputs WHERE run_id = ?1 GROUP BY how
      """, [.integer(Int64(run))], { ($0.text(at: 0) ?? "", $0.int(at: 1)) })
    {
      counts[how, default: 0] += count
    }
    return counts
  }
}
