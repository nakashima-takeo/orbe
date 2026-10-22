import Foundation

/// 出す側の行（今の集合の項目と版・出来事の流れの出来事）と、受け手の読み。
extension AutomationDatabase {
  /// 出来事の流れの残す期間。
  static let retention: TimeInterval = 30 * 24 * 3600

  /// 出した行 1 つ（書かれたまま）。
  struct Output: Equatable {
    /// 書かれた id。
    let id: String
    /// 書かれたままの JSON オブジェクト 1 行。
    let body: String
    /// 引き継いだ入力（処理の行で、入力の行の `id` を保ったものだけ）。
    let source: AutomationSourceRef?
  }

  /// 出す側の確定の結果。
  struct Written: Equatable {
    /// 出力ごとの、今その出力を表す行（足さなかった重なりは nil）。
    var rows: [AutomationRowRef?] = []
    /// 新しく有効にした行（新しい項目と出来事）の、出力の位置。
    var fresh: [Int] = []
    /// 出来事の流れで、残す期間の内に同じ id を出したので足さなかった数。
    var duplicates = 0
    /// 無効にした項目。
    var invalidated: [Int] = []
    /// 足した版（既にある項目の中身が変わった）の数。
    var versioned = 0

    /// 何かが変わったか（項目が有効になる・版が足される・項目が無効になる・出来事が足される）。
    var changed: Bool { !fresh.isEmpty || !invalidated.isEmpty || versioned > 0 }

  }

  /// 今の集合の部品の出力を照らす。結果の行ごとに同じ（部品・書かれた id）の今有効な項目を引き、無ければ新しい項目と版を
  /// 足し、あって引き継ぎ元も中身も同じなら何もせず、中身だけ違えば版を足す。引き継ぎ元が違えば今の項目を無効にして新しい
  /// 項目にする。`replacing` なら結果に無い今有効な項目を無効にする（試走の与えた行は足すだけ）。
  func writeItems(
    of part: AutomationPartID, _ outputs: [Output], at: Date, replacing: Bool = true
  ) throws -> Written {
    let p = Int64(part.rawValue)
    var written = Written()
    var live = Dictionary(
      uniqueKeysWithValues: try db.select(
        """
        SELECT i.written_id, i.id, i.source_item_id, i.source_event_id, v.id, v.body
        FROM items i JOIN item_versions v ON v.id = \(Self.currentVersion(of: "i.id"))
        WHERE i.part_id = ? AND i.valid_to IS NULL
        """, [.integer(p)]
      ) { s in
        (
          s.text(at: 0) ?? "",
          (
            id: s.int(at: 1), source: Self.source(s, item: 2, event: 3), version: s.int(at: 4),
            body: s.text(at: 5)
          )
        )
      })
    for output in outputs {
      if let current = live.removeValue(forKey: output.id) {
        if current.source == output.source {
          if current.body == output.body {
            written.rows.append(.version(current.version))
          } else {
            try db.run(
              "INSERT INTO item_versions (item_id, body, valid_from) VALUES (?, ?, ?)",
              [.integer(Int64(current.id)), .text(output.body), Self.instant(at)])
            written.rows.append(.version(Int(db.lastInsertRowID)))
            written.versioned += 1
          }
          continue
        }
        try invalidate(item: current.id, at: at)
        written.invalidated.append(current.id)
      }
      let seq = try nextSeq(of: part, "last_item_seq")
      try db.run(
        """
        INSERT INTO items (part_id, seq, written_id, source_item_id, source_event_id, valid_from)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [.integer(p), .integer(seq), .text(output.id)] + Self.values(output.source)
          + [Self.instant(at)])
      let item = db.lastInsertRowID
      try db.run(
        "INSERT INTO item_versions (item_id, body, valid_from) VALUES (?, ?, ?)",
        [.integer(item), .text(output.body), Self.instant(at)])
      written.fresh.append(written.rows.count)
      written.rows.append(.version(Int(db.lastInsertRowID)))
    }
    if replacing {
      for current in live.values {
        try invalidate(item: current.id, at: at)
        written.invalidated.append(current.id)
      }
    }
    return written
  }

  /// 出来事の流れの部品の出力を足す。`distinct` なら、残す期間の内に同じ部品が同じ書かれた id を出していれば同じ出来事として
  /// 足さない（中身が違っても）。行が保存の都合で残っていても、見分けは残す期間の内かで決める。
  func writeEvents(
    of part: AutomationPartID, _ outputs: [Output], at: Date, distinct: Bool = true
  ) throws -> Written {
    let p = Int64(part.rawValue)
    var written = Written()
    for output in outputs {
      if distinct {
        let seen = try db.select(
          """
          SELECT 1 FROM events WHERE part_id = ? AND written_id = ? AND created_at >= ? LIMIT 1
          """, [.integer(p), .text(output.id), Self.cutoff(at)]
        ) { _ in true }
        if !seen.isEmpty {
          written.duplicates += 1
          written.rows.append(nil)
          continue
        }
      }
      let seq = try nextSeq(of: part, "last_event_seq")
      try db.run(
        """
        INSERT INTO events (part_id, seq, created_at, written_id, body, source_item_id,
          source_event_id)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [.integer(p), .integer(seq), Self.instant(at), .text(output.id), .text(output.body)]
          + Self.values(output.source))
      written.fresh.append(written.rows.count)
      written.rows.append(.event(Int(db.lastInsertRowID)))
    }
    return written
  }

  /// 部品の今有効な項目をすべて無効にし、無効にした項目を返す（性質の書き換え・部品を外す）。
  @discardableResult func invalidateItems(of part: AutomationPartID, at: Date) throws -> [Int] {
    let ids = try db.select(
      "SELECT id FROM items WHERE part_id = ? AND valid_to IS NULL",
      [.integer(Int64(part.rawValue))]
    ) { $0.int(at: 0) }
    for id in ids { try invalidate(item: id, at: at) }
    return ids
  }

  private func invalidate(item: Int, at: Date) throws {
    try db.run(
      "UPDATE items SET valid_to = max(valid_from, ?) WHERE id = ?",
      [Self.instant(at), .integer(Int64(item))])
  }

  private func nextSeq(of part: AutomationPartID, _ column: String) throws -> Int64 {
    let p: SQLiteValue = .integer(Int64(part.rawValue))
    try db.run("UPDATE parts SET \(column) = \(column) + 1 WHERE id = ?", [p])
    return try db.select("SELECT \(column) FROM parts WHERE id = ?", [p]) { $0.int64(at: 0) }
      .first ?? 0
  }

  /// 部品が項目・出来事にそれぞれ最後に振った通し番号。
  func lastSeqs(of part: AutomationPartID) throws -> AutomationSeqs {
    try db.select(
      "SELECT last_item_seq, last_event_seq FROM parts WHERE id = ?",
      [.integer(Int64(part.rawValue))]
    ) { AutomationSeqs(item: $0.int(at: 0), event: $0.int(at: 1)) }.first ?? AutomationSeqs()
  }

  /// 部品の今有効な項目のリンク（取得の最新の結果）。リンクの無い項目は入らない。
  func liveLinks(of part: AutomationPartID) throws -> Set<String> {
    Set(
      try db.select(
        """
        SELECT v.link FROM items i JOIN item_versions v ON v.id = \(Self.currentVersion(of: "i.id"))
        WHERE i.part_id = ? AND i.valid_to IS NULL AND v.link IS NOT NULL
        """, [.integer(Int64(part.rawValue))]
      ) { $0.text(at: 0) ?? "" })
  }

  /// 項目を出どころに持つ候補を下げる候補の ID（覚えていて、判断が無く、対応済みでないもの）。
  func openProposals(originatingIn items: [Int]) throws -> [Int] {
    guard !items.isEmpty else { return [] }
    let list = items.map(String.init).joined(separator: ",")
    return try db.select(
      """
      SELECT q.id FROM proposals q
      JOIN held_proposals h ON h.proposal_id = q.id
      JOIN item_versions v ON v.id = q.origin_version_id
      WHERE v.item_id IN (\(list)) AND h.resolved_at IS NULL
        AND q.id NOT IN (SELECT proposal_id FROM settlements)
      """, []
    ) { $0.int(at: 0) }
  }

  // MARK: - 値

  /// 項目の今の版の ID を引く SQL の式（`item` は項目の ID の式）。版は足すだけなので、最も大きい ID が今の版。
  static func currentVersion(of item: String) -> String {
    "(SELECT max(id) FROM item_versions WHERE item_id = \(item))"
  }

  static func cutoff(_ now: Date) -> SQLiteValue {
    instant(now.addingTimeInterval(-retention))
  }

  static func source(_ s: SQLiteStatement, item: Int, event: Int) -> AutomationSourceRef? {
    if let id = s.optionalInt64(at: item) { return .item(Int(id)) }
    if let id = s.optionalInt64(at: event) { return .event(Int(id)) }
    return nil
  }

  static func values(_ source: AutomationSourceRef?) -> [SQLiteValue] {
    switch source {
    case .item(let id): [.integer(Int64(id)), .null]
    case .event(let id): [.null, .integer(Int64(id))]
    case nil: [.null, .null]
    }
  }
}
