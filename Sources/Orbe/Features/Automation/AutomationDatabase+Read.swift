import Foundation

/// 受け手の読み——上流の行を読む・読んだ位置を進める・読む前に期限で消えた数。
extension AutomationDatabase {
  /// 受け手が 1 つのつながりから読む範囲。
  struct Reading {
    let edge: AutomationNodeEdge
    /// 読んだ位置。
    let read: AutomationSeqs
    /// 読む上限の番号（契機の始まりの時点の上流の最後の番号。無ければ今の最後の番号）。
    let ceiling: AutomationSeqs
  }

  /// 受け手の 1 つのつながりの読んだ位置と、上流の最後の番号。
  struct Position: Equatable {
    let read: AutomationSeqs
    let last: AutomationSeqs
  }

  /// 受け手のつながりごとの読んだ位置と、上流の最後の番号。
  func positions(of receiver: AutomationNodeID) throws -> [AutomationNodeID: Position] {
    Dictionary(
      uniqueKeysWithValues: try db.select(
        """
        SELECT e.from_node_id, e.read_item_seq, e.read_event_seq, n.last_item_seq, n.last_event_seq
        FROM node_edges e JOIN nodes n ON n.id = e.from_node_id WHERE e.to_node_id = ?
        """, [.integer(Int64(receiver.rawValue))]
      ) { s in
        (
          AutomationNodeID(s.int(at: 0)),
          Position(
            read: AutomationSeqs(item: s.int(at: 1), event: s.int(at: 2)),
            last: AutomationSeqs(item: s.int(at: 3), event: s.int(at: 4)))
        )
      })
  }

  /// つながりの上流の行を読む。take が new なら読んだ位置より後の番号だけ、all なら位置によらず、今有効な項目の今の版と残す
  /// 期間の内の出来事を、どちらも上限の番号まで。
  func rows(_ reading: Reading, now: Date) throws -> [AutomationIntake.Row] {
    let up = reading.edge.from
    let p: SQLiteValue = .integer(Int64(up.rawValue))
    let all = reading.edge.take == .all
    let items = try db.select(
      """
      SELECT i.id, i.seq, i.written_id, i.valid_from, i.source_item_id, i.source_event_id, v.id, v.body,
        v.link
      FROM items i JOIN item_versions v ON v.id = \(Self.currentVersion(of: "i.id"))
      WHERE i.node_id = ? AND i.valid_to IS NULL AND i.seq > ? AND i.seq <= ? ORDER BY i.seq
      """,
      [p, .integer(Int64(all ? 0 : reading.read.item)), .integer(Int64(reading.ceiling.item))]
    ) { s in
      (
        item: s.int(at: 0), seq: s.int(at: 1), written: s.text(at: 2) ?? "",
        at: AutomationPersistence.date(s.int64(at: 3)), source: Self.source(s, item: 4, event: 5),
        version: s.int(at: 6), body: s.text(at: 7) ?? "{}", link: s.text(at: 8)
      )
    }
    let events = try db.select(
      """
      SELECT id, seq, written_id, created_at, source_item_id, source_event_id, body, link FROM events
      WHERE node_id = ? AND created_at >= ? AND seq > ? AND seq <= ? ORDER BY seq
      """,
      [
        p, try eventCutoff(of: up, now: now), .integer(Int64(all ? 0 : reading.read.event)),
        .integer(Int64(reading.ceiling.event)),
      ]
    ) { s in
      (
        event: s.int(at: 0), seq: s.int(at: 1), written: s.text(at: 2) ?? "",
        at: AutomationPersistence.date(s.int64(at: 3)), source: Self.source(s, item: 4, event: 5),
        body: s.text(at: 6) ?? "{}", link: s.text(at: 7)
      )
    }
    var rows: [AutomationIntake.Row] = []
    for item in items {
      let id = Self.downstreamId(item.written, of: up, inherited: item.source != nil)
      rows.append(
        AutomationIntake.Row(
          from: up, table: .item, seq: item.seq, ref: .version(item.version),
          source: .item(item.item), id: id,
          text: AutomationPrompts.replacing(id: id, in: item.body), at: item.at, link: item.link,
          unread: item.seq > reading.read.item))
    }
    for event in events {
      let id = Self.downstreamId(event.written, of: up, inherited: event.source != nil)
      rows.append(
        AutomationIntake.Row(
          from: up, table: .event, seq: event.seq, ref: .event(event.event),
          source: .event(event.event), id: id,
          text: AutomationPrompts.replacing(id: id, in: event.body), at: event.at, link: event.link,
          unread: event.seq > reading.read.event))
    }
    return rows
  }

  /// 下流へ渡す id。入力を引き継いだ行は書かれた id のまま（下流が入力と照らせる）、それ以外は `<ノード ID>:<書かれた id>`
  /// （ノードをまたいで重ならない）。
  static func downstreamId(_ written: String, of nodeId: AutomationNodeID, inherited: Bool)
    -> String
  {
    inherited ? written : "\(nodeId):\(written)"
  }

  /// 読む前に期限で消えた出来事の数: 上流の出来事の番号の（`from`, `to`] のうち、残す期間の内に残っていないもの。
  func lapsed(of up: AutomationNodeID, from: Int, to: Int, now: Date) throws -> Int {
    guard to > from else { return 0 }
    let alive =
      try db.select(
        "SELECT count(*) FROM events WHERE node_id = ? AND seq > ? AND seq <= ? AND created_at >= ?",
        [
          .integer(Int64(up.rawValue)), .integer(Int64(from)), .integer(Int64(to)),
          try eventCutoff(of: up, now: now),
        ]
      ) { $0.int(at: 0) }.first ?? 0
    return to - from - alive
  }

  /// 読んだ位置を進める（下がらない）。
  func advance(_ receiver: AutomationNodeID, _ reach: [AutomationIntake.Reach]) throws {
    for reach in reach {
      let column = reach.table == .item ? "read_item_seq" : "read_event_seq"
      try db.run(
        "UPDATE node_edges SET \(column) = max(\(column), ?) WHERE to_node_id = ? AND from_node_id = ?",
        [
          .integer(Int64(reach.seq)), .integer(Int64(receiver.rawValue)),
          .integer(Int64(reach.from.rawValue)),
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
}

extension AutomationDatabase {
  /// 受け手 `node` の読み。`baseline` はつながりごとの読む上限の番号（契機の始まりの時点の上流の最後の番号。無ければ今の最後の
  /// 番号）。読んだ位置を進める先までの、読む前に期限で消えた出来事を数えて添える。
  func read(
    _ node: AutomationGraph.Node, baseline: [AutomationNodeID: AutomationSeqs]?,
    context: AutomationIntake.Context
  ) throws -> AutomationIntake.Read {
    let positions = try self.positions(of: node.id)
    var rows: [AutomationIntake.Row] = []
    var ceilings: [AutomationIntake.Ceiling] = []
    for edge in node.inputs {
      guard let position = positions[edge.from] else { continue }
      let base = baseline?[edge.from] ?? position.last
      let ceiling = AutomationIntake.Ceiling(
        from: edge.from,
        seqs: AutomationSeqs(
          item: min(base.item, position.last.item), event: min(base.event, position.last.event)))
      ceilings.append(ceiling)
      rows += try self.rows(
        Reading(edge: edge, read: position.read, ceiling: ceiling.seqs), now: context.now)
    }
    var read = AutomationIntake.read(by: node, rows, ceilings: ceilings, in: context)
    for reach in read.reach where reach.table == .event {
      guard let from = positions[reach.from]?.read.event else { continue }
      read.lapsed += try lapsed(of: reach.from, from: from, to: reach.seq, now: context.now)
    }
    return read
  }
}

extension AutomationDatabase {
  /// 受け手 `node` が今読めば取る行の数と、そのどれかが古さの上限を過ぎる最も早い時刻。`closed` はリンクが判定の判断待ちで
  /// ない覚えている候補のリンクか。
  func pending(_ node: AutomationGraph.Node, closed: @escaping (String) -> Bool, now: Date) throws
    -> AutomationPending
  {
    let taken = try read(
      node, baseline: nil, context: AutomationIntake.Context(closed: closed, now: now)
    ).taken
    let ages = Dictionary(uniqueKeysWithValues: node.inputs.map { ($0.from, $0.maxAgeHours) })
    let expiries = taken.compactMap { row in
      ages[row.from].flatMap { $0 }.map { row.at.addingTimeInterval(TimeInterval($0) * 3600) }
    }
    return AutomationPending(count: taken.count, expiresAt: expiries.min())
  }
}

extension AutomationDatabase {
  /// 判定 `judge` が `take: all` のつながりで毎回読み直す出来事（残す期間と古さの上限の内）のリンク。
  func linksReadAgain(by judge: AutomationGraph.Node, now: Date) throws -> Set<String> {
    var links = Set<String>()
    for edge in judge.inputs where edge.take == .all {
      let since = edge.maxAgeHours.map { now.addingTimeInterval(-TimeInterval($0) * 3600) }
      let cutoff = try eventCutoff(of: edge.from, now: now)
      links.formUnion(
        try db.select(
          """
          SELECT DISTINCT link FROM events
          WHERE node_id = ? AND created_at >= max(?, ?) AND link IS NOT NULL
          """,
          [
            .integer(Int64(edge.from.rawValue)), cutoff, since.map(Self.instant) ?? cutoff,
          ]
        ) { $0.text(at: 0) ?? "" })
    }
    return links
  }
}
