import Foundation

/// 受け手の読み——上流の行を読む・出どころをたどる・読んだ位置を進める・読む前に期限で消えた数。
extension AutomationDatabase {
  /// 受け手が 1 つのつながりから読む範囲。
  struct Reading {
    let edge: AutomationPartEdge
    /// 読んだ位置（項目・出来事）。
    let readItem: Int
    let readEvent: Int
    /// 読む上限の番号（契機の始まりの時点の上流の最後の番号。無ければ今の最後の番号）。
    let ceilingItem: Int
    let ceilingEvent: Int
  }

  /// 受け手の 1 つのつながりの読んだ位置と、上流の最後の番号。
  struct Position {
    let item: Int
    let event: Int
    let lastItem: Int
    let lastEvent: Int
  }

  /// 受け手のつながりごとの読んだ位置と、上流の最後の番号。
  func readings(of receiver: AutomationGraph.Node) throws -> [AutomationPartID: Position] {
    Dictionary(
      uniqueKeysWithValues: try db.select(
        """
        SELECT e.from_part_id, e.read_item_seq, e.read_event_seq, p.last_item_seq, p.last_event_seq
        FROM part_edges e JOIN parts p ON p.id = e.from_part_id WHERE e.to_part_id = ?
        """, [.integer(Int64(receiver.id.rawValue))]
      ) { s in
        (
          AutomationPartID(s.int(at: 0)),
          Position(
            item: s.int(at: 1), event: s.int(at: 2), lastItem: s.int(at: 3),
            lastEvent: s.int(at: 4))
        )
      })
  }

  /// つながりの上流の行を読む。take が new なら読んだ位置より後の番号だけ、all なら位置によらず、今有効な項目の今の版と残す
  /// 期間の内の出来事を、どちらも上限の番号まで。`graph` は出どころを持つか（たどった先が取得の行か）を見る今のグラフ。
  func rows(_ reading: Reading, graph: AutomationGraph, now: Date) throws -> [AutomationInbox.Row] {
    let up = reading.edge.from
    let p: SQLiteValue = .integer(Int64(up.rawValue))
    let all = reading.edge.take == .all
    let items = try db.select(
      """
      SELECT i.id, i.seq, i.written_id, i.valid_from, i.source_item_id, i.source_event_id, v.id, v.body
      FROM items i JOIN item_versions v
        ON v.id = (SELECT max(id) FROM item_versions WHERE item_id = i.id)
      WHERE i.part_id = ? AND i.valid_to IS NULL AND i.seq > ? AND i.seq <= ? ORDER BY i.seq
      """, [p, .integer(Int64(all ? 0 : reading.readItem)), .integer(Int64(reading.ceilingItem))]
    ) { s in
      (
        item: s.int(at: 0), seq: s.int(at: 1), written: s.text(at: 2) ?? "",
        at: AutomationPersistence.date(s.int64(at: 3)), source: Self.source(s, item: 4, event: 5),
        version: s.int(at: 6), body: s.text(at: 7) ?? "{}"
      )
    }
    let events = try db.select(
      """
      SELECT id, seq, written_id, created_at, source_item_id, source_event_id, body FROM events
      WHERE part_id = ? AND created_at >= ? AND seq > ? AND seq <= ? ORDER BY seq
      """,
      [
        p, Self.cutoff(now), .integer(Int64(all ? 0 : reading.readEvent)),
        .integer(Int64(reading.ceilingEvent)),
      ]
    ) { s in
      (
        event: s.int(at: 0), seq: s.int(at: 1), written: s.text(at: 2) ?? "",
        at: AutomationPersistence.date(s.int64(at: 3)), source: Self.source(s, item: 4, event: 5),
        body: s.text(at: 6) ?? "{}"
      )
    }
    var rows: [AutomationInbox.Row] = []
    for item in items {
      let id = item.source == nil ? "\(up):\(item.written)" : item.written
      rows.append(
        AutomationInbox.Row(
          edge: up, table: .item, seq: item.seq, ref: .version(item.version),
          source: .item(item.item), id: id,
          text: AutomationPrompts.replacing(id: id, in: item.body), at: item.at,
          origin: try origin(of: .item(item.item), graph: graph),
          unread: item.seq > reading.readItem))
    }
    for event in events {
      let id = event.source == nil ? "\(up):\(event.written)" : event.written
      rows.append(
        AutomationInbox.Row(
          edge: up, table: .event, seq: event.seq, ref: .event(event.event),
          source: .event(event.event), id: id,
          text: AutomationPrompts.replacing(id: id, in: event.body), at: event.at,
          origin: try origin(of: .event(event.event), graph: graph),
          unread: event.seq > reading.readEvent))
    }
    return rows
  }

  /// 引き継ぎをたどった先の行。それを出した部品の今の役割が取得なら出どころ（候補のリンクと本文の元）で、ほかは出どころなし。
  /// 項目は今の版を指す。
  func origin(of start: AutomationSourceRef, graph: AutomationGraph) throws -> AutomationInbox
    .Origin?
  {
    var current = start
    while true {
      let next: [(part: Int, source: AutomationSourceRef?)]
      switch current {
      case .item(let id):
        next = try db.select(
          "SELECT part_id, source_item_id, source_event_id FROM items WHERE id = ?",
          [.integer(Int64(id))]
        ) { (part: $0.int(at: 0), source: Self.source($0, item: 1, event: 2)) }
      case .event(let id):
        next = try db.select(
          "SELECT part_id, source_item_id, source_event_id FROM events WHERE id = ?",
          [.integer(Int64(id))]
        ) { (part: $0.int(at: 0), source: Self.source($0, item: 1, event: 2)) }
      }
      guard let row = next.first else { return nil }
      if let source = row.source {
        current = source
        continue
      }
      let part = AutomationPartID(row.part)
      guard graph.node(part)?.role.isFetch == true else { return nil }
      return try originRow(current, part: part)
    }
  }

  private func originRow(_ source: AutomationSourceRef, part: AutomationPartID) throws
    -> AutomationInbox.Origin?
  {
    let found: [(ref: AutomationRowRef, body: String?)]
    switch source {
    case .item(let id):
      found = try db.select(
        "SELECT id, body FROM item_versions WHERE item_id = ? ORDER BY id DESC LIMIT 1",
        [.integer(Int64(id))]
      ) { (ref: .version($0.int(at: 0)), body: $0.text(at: 1)) }
    case .event(let id):
      found = try db.select("SELECT id, body FROM events WHERE id = ?", [.integer(Int64(id))]) {
        (ref: .event($0.int(at: 0)), body: $0.text(at: 1))
      }
    }
    guard let row = found.first, let item = Self.decode(AutomationItem.self, row.body) else {
      return nil
    }
    return AutomationInbox.Origin(part: part, row: row.ref, item: item)
  }

  /// 読む前に期限で消えた出来事の数: 上流の出来事の番号の（`from`, `to`] のうち、残す期間の内に残っていないもの。
  func lapsed(of up: AutomationPartID, from: Int, to: Int, now: Date) throws -> Int {
    guard to > from else { return 0 }
    let alive =
      try db.select(
        "SELECT count(*) FROM events WHERE part_id = ? AND seq > ? AND seq <= ? AND created_at >= ?",
        [
          .integer(Int64(up.rawValue)), .integer(Int64(from)), .integer(Int64(to)),
          Self.cutoff(now),
        ]
      ) { $0.int(at: 0) }.first ?? 0
    return to - from - alive
  }

  /// 読んだ位置を進める（下がらない）。
  func advance(_ receiver: AutomationPartID, _ reach: [AutomationInbox.Reach]) throws {
    for reach in reach {
      let column = reach.table == .item ? "read_item_seq" : "read_event_seq"
      try db.run(
        "UPDATE part_edges SET \(column) = max(\(column), ?) WHERE to_part_id = ? AND from_part_id = ?",
        [
          .integer(Int64(reach.seq)), .integer(Int64(receiver.rawValue)),
          .integer(Int64(reach.edge.rawValue)),
        ])
    }
  }

  /// 回が読んだ行と、その扱い。
  func insertInputs(of run: Int, _ inputs: [(ref: AutomationRowRef, how: String)]) throws {
    for input in inputs {
      switch input.ref {
      case .version(let id):
        try db.run(
          "INSERT OR REPLACE INTO run_item_inputs (run_id, version_id, how) VALUES (?, ?, ?)",
          [.integer(Int64(run)), .integer(Int64(id)), .text(input.how)])
      case .event(let id):
        try db.run(
          "INSERT OR REPLACE INTO run_event_inputs (run_id, event_id, how) VALUES (?, ?, ?)",
          [.integer(Int64(run)), .integer(Int64(id)), .text(input.how)])
      }
    }
  }

  /// 行の下流へ渡す 1 行（参照から）。試走の与えた行を読み直すのに使う。
  func body(of ref: AutomationRowRef) throws -> String? {
    switch ref {
    case .version(let id):
      try db.select("SELECT body FROM item_versions WHERE id = ?", [.integer(Int64(id))]) {
        $0.text(at: 0)
      }.first ?? nil
    case .event(let id):
      try db.select("SELECT body FROM events WHERE id = ?", [.integer(Int64(id))]) {
        $0.text(at: 0)
      }.first ?? nil
    }
  }
}

/// 試走が根の受け手の読みに掛ける上書き。与えた行は読んだ位置によらず読み、その回が有効にした行と与えた行は先頭から `limit`
/// 行に絞る（絞った残りは読んだものとして流さない）。
struct AutomationReadOverride {
  let edge: AutomationPartID
  let given: Set<AutomationRowRef>
  let fresh: Set<AutomationRowRef>
  let limit: Int?
}

extension AutomationDatabase {
  /// 受け手 `node` の読み。`baseline` はつながりごとの読む上限の番号（契機の始まりの時点の上流の最後の番号。無ければ今の最後の
  /// 番号）。読んだ位置を進める先までの、読む前に期限で消えた出来事を数えて添える。
  func read(
    _ node: AutomationGraph.Node, in graph: AutomationGraph,
    baseline: [AutomationPartID: (item: Int, event: Int)]?, context: AutomationInbox.Context,
    overrides: [AutomationReadOverride] = []
  ) throws -> AutomationInbox.Read {
    let readings = try self.readings(of: node)
    var rows: [AutomationInbox.Row] = []
    var ceilings: [AutomationInbox.Ceiling] = []
    for edge in node.inputs {
      guard let position = readings[edge.from] else { continue }
      let ceiling = AutomationInbox.Ceiling(
        edge: edge.from,
        item: min(baseline?[edge.from]?.item ?? position.lastItem, position.lastItem),
        event: min(baseline?[edge.from]?.event ?? position.lastEvent, position.lastEvent))
      ceilings.append(ceiling)
      let override = overrides.first { $0.edge == edge.from }
      var read = edge
      if override != nil { read.take = .all }
      var found = try self.rows(
        Reading(
          edge: read, readItem: position.item, readEvent: position.event,
          ceilingItem: ceiling.item, ceilingEvent: ceiling.event), graph: graph, now: context.now)
      if let override {
        found = found.compactMap { row in
          if override.given.contains(row.ref) { return row.forcedUnread }
          return edge.take == .all || row.unread ? row : nil
        }
        if let limit = override.limit {
          let flowing = found.filter {
            override.fresh.contains($0.ref) || override.given.contains($0.ref)
          }
          .sorted(by: AutomationInbox.order)
          let dropped = Set(flowing.dropFirst(limit).map(\.ref))
          found.removeAll { dropped.contains($0.ref) }
        }
      }
      rows += found
    }
    var read = AutomationInbox.read(by: node, rows, ceilings: ceilings, in: context)
    for reach in read.reach where reach.table == .event {
      guard let from = readings[reach.edge]?.event else { continue }
      read.lapsed += try lapsed(of: reach.edge, from: from, to: reach.seq, now: context.now)
    }
    return read
  }
}

extension AutomationInbox.Row {
  /// 読んだ位置によらず読む行として。
  fileprivate var forcedUnread: Self {
    Self(
      edge: edge, table: table, seq: seq, ref: ref, source: source, id: id, text: text, at: at,
      origin: origin, unread: true)
  }
}

/// 受け手の「読めば取る行」。
struct AutomationPending: Equatable {
  let count: Int
  /// 数えた行のどれかが古さの上限を過ぎる最も早い時刻。
  let expiresAt: Date?
}

extension AutomationDatabase {
  /// 受け手 `node` が今読めば取る行の数と、そのどれかが古さの上限を過ぎる最も早い時刻。`proposed` は
  /// リンクに候補があるか。
  func pending(
    _ node: AutomationGraph.Node, in graph: AutomationGraph, proposed: @escaping (String) -> Bool,
    now: Date
  ) throws -> AutomationPending {
    let taken = try read(
      node, in: graph, baseline: nil,
      context: AutomationInbox.Context(proposed: proposed, now: now)
    ).taken
    let ages = Dictionary(uniqueKeysWithValues: node.inputs.map { ($0.from, $0.maxAgeHours) })
    let expiries = taken.compactMap { row in
      ages[row.edge].flatMap { $0 }.map { row.at.addingTimeInterval(TimeInterval($0) * 3600) }
    }
    return AutomationPending(count: taken.count, expiresAt: expiries.min())
  }
}
