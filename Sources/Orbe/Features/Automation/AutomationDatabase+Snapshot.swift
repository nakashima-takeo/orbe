import Foundation

/// 起動時の読み。形が合った後の値の読めなさは、その件だけに閉じ込める——定義が今の検証を通らない自動化は「定義を読めない」、
/// 中身の JSON を読めない回の記録は「不明な記録」、指す行や値が読めない候補は「読めない候補」として残し、ほかは普段どおり読む。
/// 読みの SQL の失敗は投げる（そのセッションは書かない）。
extension AutomationDatabase {
  static func snapshot(_ db: SQLiteDatabase, now: Date) throws -> AutomationSnapshot {
    let database = AutomationDatabase(db)
    var automations: [Automation] = []
    var unreadable: [AutomationUnreadable] = []
    for row in try db.select(
      "SELECT id, name, notify, paused_at, version, created_at FROM automations ORDER BY id", [],
      {
        AutomationRow(
          id: $0.int(at: 0), name: $0.text(at: 1) ?? "", notify: $0.text(at: 2),
          pausedAt: $0.optionalInt64(at: 3), version: $0.int(at: 4), createdAt: $0.int64(at: 5))
      })
    {
      switch try database.automation(row) {
      case .readable(let automation): automations.append(automation)
      case .unreadable(let broken): unreadable.append(broken)
      }
    }
    let (proposals, unreadableProposals) = try database.heldProposals()
    var snapshot = AutomationSnapshot(
      automations: automations, unreadable: unreadable, proposals: proposals,
      unreadableProposals: unreadableProposals)
    let links = snapshot.heldLinks
    for index in snapshot.automations.indices {
      let automation = snapshot.automations[index]
      for node in automation.graph.nodes where !node.inputs.isEmpty {
        snapshot.automations[index].parts[node.id]?.inbox = try database.read(
          node, in: automation.graph, baseline: nil,
          context: AutomationInbox.Context(proposed: links.contains, now: now, batch: false)
        ).taken.count
      }
    }
    return snapshot
  }

  /// `automations` の 1 行。
  private struct AutomationRow {
    let id: Int
    let name: String
    let notify: String?
    let pausedAt: Int64?
    let version: Int
    let createdAt: Int64
  }

  private enum Assembled {
    case readable(Automation)
    case unreadable(AutomationUnreadable)
  }

  /// 自動化 1 つを、部品・つながり・使う動作の定義の行から組んで検証する。通らなければ定義を読めない自動化。
  private func automation(_ row: AutomationRow) throws -> Assembled {
    let parts = try partRows(of: row.id)
    var object: [String: Any] = ["name": row.name, "parts": parts.map(\.object)]
    if let notify = row.notify { object["notify"] = notify }
    func broken(_ reason: String) -> Assembled {
      .unreadable(
        AutomationUnreadable(
          id: row.id, name: try? TaskStore.validTitle(row.name), version: row.version,
          definition: Self.jsonText(object), reason: reason, parts: parts.map(\.id)))
    }
    if let problem = parts.lazy.compactMap(\.problem).first { return broken(problem) }
    let checked: (name: String, parts: [AutomationGraph.Checked])
    do throws(AutomationError) {
      checked = try AutomationDefinition.decode(object).checked()
    } catch {
      return broken(Self.reason(error))
    }
    let graph = AutomationGraph(
      checked.parts,
      parts: zip(checked.parts, parts).map { checked, row in
        AutomationPart(
          id: row.id, key: checked.part.key, name: checked.part.name,
          trigger: checked.part.trigger, maxItems: checked.part.maxItems, defId: row.defId)
      })
    var states: [AutomationPartID: AutomationPartState] = [:]
    for part in parts { states[part.id] = try state(of: part) }
    return .readable(
      Automation(
        id: row.id, name: checked.name, notify: row.notify.flatMap(AutomationNotify.init),
        graph: graph, pausedAt: row.pausedAt.map(AutomationPersistence.date),
        version: row.version, createdAt: AutomationPersistence.date(row.createdAt), parts: states))
  }

  /// 自動化の外していない部品の行。外の形の JSON に組めた分と、組めなかった理由を持つ。
  private struct PartRow {
    let id: AutomationPartID
    let defId: AutomationDefID
    let object: [String: Any]
    let problem: String?
    let addedAt: Date
    let lastItemSeq: Int
    let lastEventSeq: Int
    let pendingDrops: String?
  }

  private func partRows(of automation: Int) throws -> [PartRow] {
    let rows = try db.select(
      """
      SELECT p.id, p.key, p.name, p.trigger, p.max_items, p.def_id, d.kind, a.action, p.added_at,
        p.last_item_seq, p.last_event_seq, p.pending_drops
      FROM parts p JOIN part_defs d ON d.id = p.def_id LEFT JOIN action_defs a ON a.id = p.def_id
      WHERE p.automation_id = ? AND p.removed_at IS NULL ORDER BY p.position
      """, [.integer(Int64(automation))]
    ) { s in
      (
        id: s.int(at: 0), key: s.text(at: 1) ?? "", name: s.text(at: 2) ?? "",
        trigger: s.text(at: 3), maxItems: s.optionalInt64(at: 4), defId: s.int(at: 5),
        kind: s.text(at: 6), action: s.text(at: 7), addedAt: s.int64(at: 8),
        lastItem: s.int(at: 9), lastEvent: s.int(at: 10), drops: s.text(at: 11)
      )
    }
    let keys = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.key) })
    return try rows.enumerated().map { index, row in
      var object: [String: Any] = ["id": row.id, "key": row.key, "name": row.name]
      var problem: String?
      if let trigger = row.trigger.flatMap(Self.jsonObject) {
        object["trigger"] = trigger
      } else {
        problem = "parts[\(index)].trigger: the stored trigger cannot be read"
      }
      if let maxItems = row.maxItems { object["inboxLimit"] = ["maxItems": maxItems] }
      let from = try db.select(
        """
        SELECT from_part_id, take, max_age_hours FROM part_edges WHERE to_part_id = ?
        ORDER BY position
        """, [.integer(Int64(row.id))]
      ) { s -> Any in
        let key = keys[s.int(at: 0)] ?? ""
        let take = s.text(at: 1) ?? "new"
        guard take != "new" || !s.isNull(at: 2) else { return key }
        var input: [String: Any] = ["part": key]
        if take != "new" { input["take"] = take }
        if let hours = s.optionalInt64(at: 2) { input["maxAgeHours"] = hours }
        return input
      }
      if !from.isEmpty { object["from"] = from }
      if row.kind == "composite" {
        problem =
          problem ?? "parts[\(index)]: it uses a part made of parts, which this Orbe cannot run"
      } else if let action = row.action.flatMap(Self.jsonObject) {
        object.merge(action) { current, _ in current }
      } else {
        problem = problem ?? "parts[\(index)]: the stored action cannot be read"
      }
      return PartRow(
        id: AutomationPartID(row.id), defId: AutomationDefID(row.defId), object: object,
        problem: problem, addedAt: AutomationPersistence.date(row.addedAt),
        lastItemSeq: row.lastItem, lastEventSeq: row.lastEvent, pendingDrops: row.drops)
    }
  }

  /// 部品の状態（直近の回・最新の成功・外した印・持ち越し・最後の番号・今有効な項目）。
  private func state(of part: PartRow) throws -> AutomationPartState {
    var state = AutomationPartState(addedAt: part.addedAt)
    state.runs = try records(of: part.id, limit: AutomationPartState.retainedRuns)
    state.succeededAt = try succeededAt(of: part.id)
    state.breach = try breachRecord(of: part.id).map(AutomationBreachMark.init)
    if let drops = Self.decode(AutomationDrops.self, part.pendingDrops) {
      state.pendingDrops = drops
    } else {
      NSLog("[automation] dropped unreadable carried counts of part \(part.id)")
    }
    state.lastItemSeq = part.lastItemSeq
    state.lastEventSeq = part.lastEventSeq
    state.live = try live(of: part.id)
    state.reads = Dictionary(
      uniqueKeysWithValues: try db.select(
        "SELECT from_part_id, read_item_seq, read_event_seq FROM part_edges WHERE to_part_id = ?",
        [.integer(Int64(part.id.rawValue))]
      ) {
        (
          AutomationPartID($0.int(at: 0)),
          AutomationReadPosition(item: $0.int(at: 1), event: $0.int(at: 2))
        )
      })
    return state
  }

  /// 覚えている候補。指す行や値が読めない候補は、リンクだけを持つ読めない候補にする。
  private func heldProposals() throws -> ([AutomationProposal], [AutomationUnreadableProposal]) {
    let rows = try db.select(
      """
      SELECT q.id, q.run_id, r.part_id, r.def_id, r.ended_at, p.automation_id, q.origin_version_id,
        q.origin_event_id, coalesce(v.body, e.body), coalesce(i.part_id, e.part_id), q.link, q.title,
        q.due, q.workspace, q.reason, h.resolved_at, s.outcome, s.task_id
      FROM held_proposals h JOIN proposals q ON q.id = h.proposal_id
      JOIN runs r ON r.id = q.run_id JOIN parts p ON p.id = r.part_id
      LEFT JOIN item_versions v ON v.id = q.origin_version_id
      LEFT JOIN items i ON i.id = v.item_id
      LEFT JOIN events e ON e.id = q.origin_event_id
      LEFT JOIN settlements s ON s.proposal_id = q.id
      ORDER BY q.id
      """, []
    ) { s in
      (
        id: s.int(at: 0), run: s.int(at: 1), judge: s.int(at: 2), defId: s.int(at: 3),
        endedAt: s.int64(at: 4), automation: s.optionalInt64(at: 5),
        version: s.optionalInt64(at: 6), event: s.optionalInt64(at: 7), body: s.text(at: 8),
        source: s.optionalInt64(at: 9), link: s.text(at: 10) ?? "", title: s.text(at: 11) ?? "",
        due: s.text(at: 12), workspace: s.text(at: 13), reason: s.text(at: 14),
        resolvedAt: s.optionalInt64(at: 15), outcome: s.text(at: 16),
        taskId: s.optionalInt64(at: 17)
      )
    }
    var proposals: [AutomationProposal] = []
    var unreadable: [AutomationUnreadableProposal] = []
    for row in rows {
      let state: AutomationProposal.State?
      switch (row.outcome, row.taskId, row.resolvedAt) {
      case ("accepted", let taskId?, _): state = .accepted(taskId: Int(taskId))
      case ("dismissed", nil, _): state = .dismissed
      case (nil, nil, .some): state = .resolved
      case (nil, nil, nil): state = .open
      default: state = nil
      }
      let due = row.due.map { TaskItem.DueDate($0) }
      let workspace = row.workspace.map { UUID(uuidString: $0) }
      let origin: AutomationRowRef? =
        row.version.map { .version(Int($0)) } ?? row.event.map { .event(Int($0)) }
      guard let state, let origin, let source = row.source,
        let item = Self.decode(AutomationItem.self, row.body), item.link == row.link,
        due.map({ $0 != nil }) ?? true, workspace.map({ $0 != nil }) ?? true
      else {
        unreadable.append(AutomationUnreadableProposal(id: row.id, link: row.link))
        continue
      }
      proposals.append(
        AutomationProposal(
          id: row.id, runId: row.run, automationId: row.automation.map(Int.init),
          judge: AutomationPartID(row.judge), defId: AutomationDefID(row.defId),
          source: AutomationPartID(Int(source)), origin: origin, item: item, title: row.title,
          due: due ?? nil, workspace: workspace ?? nil, reason: row.reason,
          proposedAt: AutomationPersistence.date(row.endedAt), state: state))
    }
    return (proposals, unreadable)
  }

  private static func jsonObject(_ text: String) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
  }

  /// 外の形の JSON の文（キーの順に並べる）。
  static func jsonText(_ object: Any) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
      let text = String(bytes: data, encoding: .utf8)
    else { return "{}" }
    return text
  }

  static func reason(_ error: AutomationError) -> String {
    if case .invalid(let message) = error { return message }
    return "\(error)"
  }
}
