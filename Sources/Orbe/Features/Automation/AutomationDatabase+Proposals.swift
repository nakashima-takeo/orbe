import Foundation

/// 候補（判定が出したデータ）・覚えている印・人の判断と、候補を下げる判断に使う読み。
extension AutomationDatabase {
  /// 判定のノード `nodeId` の回が出した候補を足し、覚えている印を付けて ID を返す。
  func insert(proposal: AutomationNodePass.Proposal, run: Int, nodeId: AutomationNodeID) throws
    -> Int
  {
    var row: [SQLiteValue] = [.null, .null]
    switch proposal.row {
    case .version(let id): row[0] = .integer(Int64(id))
    case .event(let id): row[1] = .integer(Int64(id))
    }
    let node: SQLiteValue = .integer(Int64(nodeId.rawValue))
    try db.run(
      """
      INSERT INTO proposals (run_id, node_id, version_id, event_id, link, title, due, workspace,
        reason)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [.integer(Int64(run)), node] + row + [
        .text(proposal.fields.link), .text(proposal.title), Self.text(proposal.due?.text),
        Self.text(proposal.workspace?.uuidString), Self.text(proposal.reason),
      ])
    let id = db.lastInsertRowID
    try db.run(
      "INSERT INTO held_proposals (proposal_id, node_id, link) VALUES (?, ?, ?)",
      [.integer(id), node, .text(proposal.fields.link)])
    return Int(id)
  }

  /// 判定が対応済みにした。
  func resolve(_ proposal: Int, at: Date) throws {
    try db.run(
      "UPDATE held_proposals SET resolved_at = ? WHERE proposal_id = ?",
      [Self.instant(at), .integer(Int64(proposal))])
  }

  /// 人の判断を 1 件残す。
  func settle(_ proposal: Int, _ state: AutomationProposal.State, at: Date) throws {
    let outcome: (String, SQLiteValue)
    switch state {
    case .accepted(let taskId): outcome = ("accepted", .integer(Int64(taskId)))
    case .dismissed: outcome = ("dismissed", .null)
    case .open, .resolved: preconditionFailure("only a person's decision is settled")
    }
    try db.run(
      "INSERT INTO settlements (proposal_id, decided_at, outcome, task_id) VALUES (?, ?, ?, ?)",
      [.integer(Int64(proposal)), Self.instant(at), .text(outcome.0), outcome.1])
  }

  /// 覚えている印を外す（忘れる）。判断の記録が無ければ、候補は掃除で消える。
  func forget(proposals ids: [Int]) throws {
    for id in ids {
      try db.run("DELETE FROM held_proposals WHERE proposal_id = ?", [.integer(Int64(id))])
    }
  }

  /// 判定のノードの、定義 `defId` が出した候補への人の判断の数（判断の記録の内）。
  func settlementCounts(of nodeId: AutomationNodeID, defId: AutomationNodeDefID) throws
    -> (accepted: Int, dismissed: Int)
  {
    var counts = (accepted: 0, dismissed: 0)
    for (outcome, count) in try db.select(
      """
      SELECT s.outcome, count(*) FROM settlements s JOIN proposals q ON q.id = s.proposal_id
      JOIN runs r ON r.id = q.run_id WHERE q.node_id = ? AND r.def_id = ? GROUP BY s.outcome
      """, [.integer(Int64(nodeId.rawValue)), .integer(Int64(defId.rawValue))],
      { ($0.text(at: 0), $0.int(at: 1)) })
    {
      switch outcome {
      case "accepted": counts.accepted = count
      case "dismissed": counts.dismissed = count
      default: break
      }
    }
    return counts
  }

  // MARK: - 下げる判断

  /// 覚えていて、判断が無く、対応済みでない候補（読めない候補も）。
  struct OpenProposal: Equatable {
    let id: Int
    let judge: AutomationNodeID
    let link: String
    let row: AutomationRowRef
  }

  /// 判断待ちの候補のうち、読んだ行が `items` の項目（の版）か、その項目から引き継ぎで降りた行のもの。
  func openProposals(descendingFrom items: [Int]) throws -> [OpenProposal] {
    guard !items.isEmpty else { return [] }
    var itemIds = Set(items)
    var eventIds = Set<Int>()
    var frontier = (items: items, events: [Int]())
    while !frontier.items.isEmpty || !frontier.events.isEmpty {
      let children = try sourcedBy(items: frontier.items, events: frontier.events)
      frontier = (
        children.items.filter { itemIds.insert($0).inserted },
        children.events.filter { eventIds.insert($0).inserted }
      )
    }
    return try selectOpen(
      """
      (q.version_id IN (SELECT id FROM item_versions WHERE item_id IN (\(Self.list(itemIds))))
        OR q.event_id IN (\(Self.list(eventIds))))
      """)
  }

  /// 判定のノード `judge` の判断待ちの候補（リンクを `links` で絞る。nil なら全部）。
  func openProposals(of judge: AutomationNodeID, links: Set<String>? = nil) throws
    -> [OpenProposal]
  {
    guard let links else {
      return try selectOpen("q.node_id = ?", [.integer(Int64(judge.rawValue))])
    }
    guard !links.isEmpty else { return [] }
    return try selectOpen(
      "q.node_id = ? AND q.link IN (\(Array(repeating: "?", count: links.count).joined(separator: ",")))",
      [.integer(Int64(judge.rawValue))] + links.sorted().map { .text($0) })
  }

  /// 項目 `items` のうち、今の版がリンクを持つものの、ノードとリンク。
  func linkedItems(_ items: [Int]) throws -> [(nodeId: AutomationNodeID, link: String)] {
    guard !items.isEmpty else { return [] }
    return try db.select(
      """
      SELECT i.node_id, v.link FROM items i JOIN item_versions v ON v.id = \(Self.currentVersion(of: "i.id"))
      WHERE i.id IN (\(Self.list(items))) AND v.link IS NOT NULL
      """, []
    ) { (AutomationNodeID($0.int(at: 0)), $0.text(at: 1) ?? "") }
  }

  /// 行 `row` を元にしたリンク `link` の候補が、今のものでなくなったか——元にした行か、その行が引き継ぎでたどる元の行のうち
  /// 項目のどれかが無効で、候補を出した判定の入力（直接の上流のノード `inputs`）の今有効な項目にもリンクが無い。
  func noLongerCurrent(_ row: AutomationRowRef, link: String, inputs: [AutomationNodeID]) throws
    -> Bool
  {
    guard try lineage(of: row).contains(where: \.invalid) else { return false }
    for input in inputs where try liveLinks(of: input).contains(link) { return false }
    return true
  }

  /// 引き継ぎをたどる 1 歩: 行を出したノードと、行が無効になった項目か。
  struct Lineage: Equatable {
    let nodeId: AutomationNodeID
    let invalid: Bool
  }

  /// 行から引き継ぎを元へたどった行（最初は `row` の行）。行が無ければ空。
  func lineage(of row: AutomationRowRef) throws -> [Lineage] {
    var steps: [Lineage] = []
    var next: (sql: String, id: Int)?
    switch row {
    case .version(let id):
      next = (
        """
        SELECT i.node_id, i.valid_to IS NOT NULL, i.source_item_id, i.source_event_id
        FROM item_versions v JOIN items i ON i.id = v.item_id WHERE v.id = ?
        """, id
      )
    case .event(let id): next = (Self.eventStep, id)
    }
    while case let (sql, id)? = next {
      guard
        let found = try db.select(
          sql, [.integer(Int64(id))],
          {
            (
              step: Lineage(nodeId: AutomationNodeID($0.int(at: 0)), invalid: $0.int(at: 1) != 0),
              source: Self.source($0, item: 2, event: 3)
            )
          }
        ).first
      else { break }
      steps.append(found.step)
      switch found.source {
      case .item(let id): next = (Self.itemStep, id)
      case .event(let id): next = (Self.eventStep, id)
      case nil: next = nil
      }
    }
    return steps
  }

  private static let itemStep =
    "SELECT node_id, valid_to IS NOT NULL, source_item_id, source_event_id FROM items WHERE id = ?"
  private static let eventStep =
    "SELECT node_id, 0, source_item_id, source_event_id FROM events WHERE id = ?"

  /// 行を引き継いだ（`source_item_id`・`source_event_id` が指す）項目と出来事。
  private func sourcedBy(items: [Int], events: [Int]) throws -> (items: [Int], events: [Int]) {
    var found = (items: [Int](), events: [Int]())
    for (column, ids) in [("source_item_id", items), ("source_event_id", events)] where !ids.isEmpty
    {
      found.items += try db.select(
        "SELECT id FROM items WHERE \(column) IN (\(Self.list(ids)))", [], { $0.int(at: 0) })
      found.events += try db.select(
        "SELECT id FROM events WHERE \(column) IN (\(Self.list(ids)))", [], { $0.int(at: 0) })
    }
    return found
  }

  private func selectOpen(_ condition: String, _ values: [SQLiteValue] = []) throws
    -> [OpenProposal]
  {
    try db.select(
      """
      SELECT q.id, q.node_id, q.link, q.version_id, q.event_id FROM proposals q
      JOIN held_proposals h ON h.proposal_id = q.id
      WHERE h.resolved_at IS NULL AND q.id NOT IN (SELECT proposal_id FROM settlements)
        AND \(condition)
      ORDER BY q.id
      """, values
    ) { s in
      OpenProposal(
        id: s.int(at: 0), judge: AutomationNodeID(s.int(at: 1)), link: s.text(at: 2) ?? "",
        row: s.optionalInt64(at: 3).map { .version(Int($0)) } ?? .event(s.int(at: 4)))
    }
  }

  private static func list(_ ids: some Sequence<Int>) -> String {
    ids.map(String.init).joined(separator: ",")
  }
}
