import Foundation

/// 試走が自分の写しに掛ける操作。写しのストアに対して試走だけが呼ぶ。写しは試走のもので捨てるので、ここでだけ本番の決まり
/// （出来事は見分けて足す・番号を使い回さない・出どころの項目が無効になれば候補を下げる）を崩す。どの操作も変異の 1 経路
/// （`commit`）と部品の状態の読み直しを通し、写しのメモリを写しの DB と一致させ続ける。
extension AutomationStore {
  /// 行を、部品 `part` の出力として新しい行で書く。今の集合は、同じ書かれた id の今有効な項目を無効にしてから新しい項目として
  /// 足す（今有効な項目は id ごとに 1 つのまま。この無効化では判断待ちの候補を下げない——判定は既に候補のあるリンクの行を
  /// 「既に候補がある」で捨てる）。出来事の流れは同じ id でも足す。
  func give(_ rows: [AutomationPartRow], as part: AutomationPartID, of id: Int, at: Date)
    throws(AutomationError)
  {
    let index = try index(id)
    guard let node = automations[index].graph.node(part) else {
      throw .partNotFound(id, "\(part)")
    }
    let at = TaskItem.storedInstant(at)
    try commit(sweepingAt: nil) { db, memory in
      for row in rows {
        let output = AutomationDatabase.Output(id: row.id, body: row.text, source: nil)
        if node.coverage == .currentSet {
          try db.invalidateLiveItem(of: part, written: row.id, at: at)
          try db.insertItem(of: part, output, at: at)
        } else {
          try db.insertEvent(of: part, output, at: at)
        }
      }
      try memory.reread(part, of: id, db)
      try memory.recount(id, db, now: at)
    }
  }

  /// 部品の回が新しく足した `fresh` 行のうち、番号の順で `keeping` 行を超えた分を写しから消し、その表の最後の番号を、残った
  /// 行が記録する最も大きい番号（項目の表は項目・版・無効化の番号）まで戻す。写しは、その回が新しい行を `keeping` 行だけ出
  /// した状態と同じになる（読んだ位置・読む前に期限で消えた数・起こす決まりが本番の意味のまま揃う）。確定の直後、下流が読む
  /// 前に呼ぶ。
  func trim(_ part: AutomationPartID, in id: Int, fresh: Int, keeping: Int, now: Date)
    throws(AutomationError)
  {
    guard let coverage = automation(id)?.graph.node(part)?.coverage else {
      throw .partNotFound(id, "\(part)")
    }
    try commit(sweepingAt: nil) { db, memory in
      try db.trim(part, coverage, fresh: fresh, keeping: keeping)
      try memory.reread(part, of: id, db)
      try memory.recount(id, db, now: now)
    }
  }

  /// 部品の表（出力の性質の表）の番号の上から `count` 行を、下流へ渡す 1 行で古い順に。確定の直後に呼べば、その回が新しく
  /// 足した行（時刻の一致では見分けない）。
  func latestRows(of part: AutomationPartID, in id: Int, count: Int) throws(AutomationError)
    -> [String]
  {
    guard let coverage = automation(id)?.graph.node(part)?.coverage else {
      throw .partNotFound(id, "\(part)")
    }
    return try read { try $0.latest(part, coverage, count: count).map(\.line) }
  }
}

extension AutomationDatabase {
  /// 番号の上から引いた行 1 つ。
  fileprivate struct Latest {
    let id: Int
    let seq: Int
    /// 下流へ渡す 1 行。
    let line: String
  }

  /// 部品の表の番号の上から `count` 行（古い順）。
  fileprivate func latest(_ part: AutomationPartID, _ coverage: AutomationCoverage, count: Int)
    throws -> [Latest]
  {
    let values: [SQLiteValue] = [.integer(Int64(part.rawValue)), .integer(Int64(count))]
    let sql =
      coverage == .currentSet
      ? """
      SELECT i.id, i.seq, i.written_id, i.source_item_id, i.source_event_id, v.body
      FROM items i JOIN item_versions v ON v.id = \(Self.currentVersion(of: "i.id"))
      WHERE i.part_id = ? ORDER BY i.seq DESC LIMIT ?
      """
      : """
      SELECT id, seq, written_id, source_item_id, source_event_id, body FROM events
      WHERE part_id = ? ORDER BY seq DESC LIMIT ?
      """
    let rows = try db.select(sql, values) { s in
      let id = Self.downstreamId(
        s.text(at: 2) ?? "", of: part, inherited: Self.source(s, item: 3, event: 4) != nil)
      return Latest(
        id: s.int(at: 0), seq: s.int(at: 1),
        line: AutomationPrompts.replacing(id: id, in: s.text(at: 5) ?? "{}"))
    }
    return rows.reversed()
  }

  fileprivate func trim(
    _ part: AutomationPartID, _ coverage: AutomationCoverage, fresh: Int, keeping: Int
  ) throws {
    let rows = try latest(part, coverage, count: fresh)
    guard rows.count > keeping, keeping > 0 else { return }
    for row in rows.dropFirst(keeping) {
      let id: [SQLiteValue] = [.integer(Int64(row.id))]
      if coverage == .currentSet {
        try db.run("DELETE FROM item_versions WHERE item_id = ?", id)
        try db.run("DELETE FROM items WHERE id = ?", id)
      } else {
        try db.run("DELETE FROM events WHERE id = ?", id)
      }
    }
    let (column, recorded) =
      coverage == .currentSet
      ? (
        "last_item_seq",
        """
        SELECT seq FROM items WHERE part_id = ?1
        UNION ALL SELECT valid_to_seq FROM items WHERE part_id = ?1
        UNION ALL SELECT v.seq FROM item_versions v JOIN items i ON i.id = v.item_id
          WHERE i.part_id = ?1
        """
      )
      : ("last_event_seq", "SELECT seq FROM events WHERE part_id = ?1")
    try db.run(
      "UPDATE parts SET \(column) = coalesce((SELECT max(seq) FROM (\(recorded))), 0) WHERE id = ?1",
      [.integer(Int64(part.rawValue))])
  }

  /// 同じ書かれた id の今有効な項目を無効にする。
  fileprivate func invalidateLiveItem(of part: AutomationPartID, written: String, at: Date) throws {
    for item in try db.select(
      "SELECT id FROM items WHERE part_id = ? AND written_id = ? AND valid_to IS NULL",
      [.integer(Int64(part.rawValue)), .text(written)], { $0.int(at: 0) })
    {
      try invalidate(item: item, of: part, at: at)
    }
  }
}
