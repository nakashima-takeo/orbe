import Foundation

/// 候補（判定が出したデータ）・覚えている印・人の判断と、候補を下げる判断・覚える判断に使う読み。
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

  // MARK: - 下げる判断と覚える判断

  /// 覚えている候補 1 つ（読めない候補も）。
  struct HeldProposal: Equatable {
    let id: Int
    let judge: AutomationNodeID
    let link: String
    let row: AutomationRowRef
    /// 判断待ち（人の判断が無く、対応済みでない）。
    let open: Bool
  }

  /// 覚えている候補すべて（読めない候補も）。
  func heldProposals() throws -> [HeldProposal] {
    try db.select(
      """
      SELECT q.id, q.node_id, q.link, q.version_id, q.event_id,
        h.resolved_at IS NULL AND q.id NOT IN (SELECT proposal_id FROM settlements)
      FROM proposals q JOIN held_proposals h ON h.proposal_id = q.id
      ORDER BY q.id
      """, []
    ) { s in
      HeldProposal(
        id: s.int(at: 0), judge: AutomationNodeID(s.int(at: 1)), link: s.text(at: 2) ?? "",
        row: s.optionalInt64(at: 3).map { .version(Int($0)) } ?? .event(s.int(at: 4)),
        open: s.int(at: 5) != 0)
    }
  }

  /// 下げる条件に当てる 1 件: 判定が読んだ行・リンク・判定の入力（直接の上流のノード）。
  struct Withdrawal {
    let row: AutomationRowRef
    let link: String
    let inputs: [AutomationNodeID]
  }

  /// 候補が、時刻 `now` に下げる条件を満たすか（`candidates` の順）。条件は (a) か (b) のどちらかに当てはまり、かつ (c) も満たすこと。
  /// (a) 元にした行（読んだ行と、その行が引き継ぎでたどる元の行）のうち項目のどれかが無効。
  /// (b) 元にした行がどれも出来事で、読んだ行が残す期間を過ぎている。
  /// (c) 判定の入力のどれもリンクを今の行に持たない。
  /// 覚えている候補にも、判定の確定が当てる案にも、この 1 つの読みを通す。候補の数だけ SQL を発行しない。
  func noLongerCurrent(_ candidates: [Withdrawal], now: Date) throws -> [Bool] {
    guard !candidates.isEmpty else { return [] }
    let lineages = try lineages(of: Set(candidates.map(\.row)))
    let readEvents = candidates.map { candidate -> Int? in
      guard case .event(let id) = candidate.row,
        lineages[candidate.row]?.allSatisfy(\.event) ?? true
      else { return nil }
      return id
    }
    let expired = try expiredEvents(Set(readEvents.compactMap { $0 }), now: now)
    let stale = zip(candidates, readEvents).map { candidate, event in
      (lineages[candidate.row] ?? []).contains(where: \.invalid)
        || event.map(expired.contains) ?? false
    }
    let suspects = zip(candidates, stale).filter(\.1).map(\.0)
    guard !suspects.isEmpty else { return stale }
    let current = try currentLinks(
      of: Set(suspects.flatMap(\.inputs)), among: Set(suspects.map(\.link)), now: now)
    return zip(candidates, stale).map { candidate, stale in
      stale && !candidate.inputs.contains { current[$0]?.contains(candidate.link) == true }
    }
  }

  /// ノード `nodes` の今の行が持つリンクのうち、`links` のどれかのもの（時刻 `now` の。ノードごと）。今の行とは、今有効な項目と、
  /// 残す期間の内の出来事のうち、元にした行（その行と、その行が引き継ぎでたどる元の行）に無効な項目が無いもの。
  func currentLinks(of nodes: Set<AutomationNodeID>, among links: Set<String>, now: Date) throws
    -> [AutomationNodeID: Set<String>]
  {
    guard !nodes.isEmpty, !links.isEmpty,
      let linkList = String(
        bytes: try JSONSerialization.data(withJSONObject: Array(links)), encoding: .utf8)
    else { return [:] }
    let items = try db.select(
      """
      SELECT v.id, i.node_id, v.link FROM items i
      JOIN item_versions v ON v.id = \(Self.currentVersion(of: "i.id"))
      WHERE i.node_id IN (\(Self.list(nodes.map(\.rawValue)))) AND i.valid_to IS NULL
        AND v.link IN (SELECT value FROM json_each(?))
      """, [.text(linkList)]
    ) {
      (
        row: AutomationRowRef.version($0.int(at: 0)), nodeId: AutomationNodeID($0.int(at: 1)),
        link: $0.text(at: 2) ?? ""
      )
    }
    let start = retentionStart(of: "e.node_id", now: now)
    let events = try db.select(
      """
      SELECT e.id, e.node_id, e.link FROM events e
      WHERE e.node_id IN (\(Self.list(nodes.map(\.rawValue))))
        AND e.link IN (SELECT value FROM json_each(?)) AND e.created_at >= \(start.sql)
      """, [.text(linkList)] + start.values
    ) {
      (
        row: AutomationRowRef.event($0.int(at: 0)), nodeId: AutomationNodeID($0.int(at: 1)),
        link: $0.text(at: 2) ?? ""
      )
    }
    let rows = items + events
    let lineages = try lineages(of: Set(rows.map(\.row)))
    var current: [AutomationNodeID: Set<String>] = [:]
    for row in rows where !(lineages[row.row] ?? []).contains(where: \.invalid) {
      current[row.nodeId, default: []].insert(row.link)
    }
    return current
  }

  /// 出来事 `ids` のうち、時刻 `now` に残す期間を過ぎたもの。
  private func expiredEvents(_ ids: Set<Int>, now: Date) throws -> Set<Int> {
    guard !ids.isEmpty else { return [] }
    let expired = expiredEvents(at: now)
    return Set(
      try db.select(
        "SELECT id FROM events WHERE id IN (\(Self.list(ids))) AND id IN (\(expired.sql))",
        expired.values, { $0.int(at: 0) }))
  }

  /// 引き継ぎをたどる 1 歩: 行を出したノードと、行が出来事か、無効になった項目か。
  struct Lineage: Equatable {
    let nodeId: AutomationNodeID
    let event: Bool
    let invalid: Bool
  }

  /// 行から引き継ぎを元へたどった行（最初は `row` の行）。行が無ければ空。
  func lineage(of row: AutomationRowRef) throws -> [Lineage] {
    try lineages(of: [row])[row] ?? []
  }

  /// 行ごとの `lineage(of:)`。行の数でなく、引き継ぎの深さの数だけ SQL を発行する。
  func lineages(of rows: Set<AutomationRowRef>) throws -> [AutomationRowRef: [Lineage]] {
    var steps = Dictionary(uniqueKeysWithValues: rows.map { ($0, [Lineage]()) })
    var frontier: [Hop: [AutomationRowRef]] = [:]
    for row in rows {
      switch row {
      case .version(let id): frontier[Hop(table: .version, id: id), default: []].append(row)
      case .event(let id): frontier[Hop(table: .event, id: id), default: []].append(row)
      }
    }
    while !frontier.isEmpty {
      var next: [Hop: [AutomationRowRef]] = [:]
      for table in LineageTable.allCases {
        let ids = frontier.keys.filter { $0.table == table }.map(\.id)
        guard !ids.isEmpty else { continue }
        for (id, step, source) in try db.select(
          "\(table.sql) (\(Self.list(ids)))", [],
          {
            (
              $0.int(at: 0),
              Lineage(
                nodeId: AutomationNodeID($0.int(at: 1)), event: $0.int(at: 2) != 0,
                invalid: $0.int(at: 3) != 0), Self.source($0, item: 4, event: 5)
            )
          })
        {
          let origins = frontier[Hop(table: table, id: id)] ?? []
          for origin in origins { steps[origin]?.append(step) }
          switch source {
          case .item(let id): next[Hop(table: .item, id: id), default: []] += origins
          case .event(let id): next[Hop(table: .event, id: id), default: []] += origins
          case nil: break
          }
        }
      }
      frontier = next
    }
    return steps
  }

  /// 引き継ぎをたどって次に読む行。
  private struct Hop: Hashable {
    let table: LineageTable
    let id: Int
  }

  /// 引き継ぎをたどる表。
  private enum LineageTable: CaseIterable {
    case version
    case item
    case event

    /// 行の ID・出したノード・出来事か・無効な項目か・引き継ぎ元を引く SQL（末尾に ID の並びを足す）。
    var sql: String {
      switch self {
      case .version:
        """
        SELECT v.id, i.node_id, 0, i.valid_to IS NOT NULL, i.source_item_id, i.source_event_id
        FROM item_versions v JOIN items i ON i.id = v.item_id WHERE v.id IN
        """
      case .item:
        """
        SELECT id, node_id, 0, valid_to IS NOT NULL, source_item_id, source_event_id FROM items
        WHERE id IN
        """
      case .event:
        """
        SELECT id, node_id, 1, 0, source_item_id, source_event_id FROM events WHERE id IN
        """
      }
    }
  }

  private static func list(_ ids: some Sequence<Int>) -> String {
    ids.map(String.init).joined(separator: ",")
  }
}
