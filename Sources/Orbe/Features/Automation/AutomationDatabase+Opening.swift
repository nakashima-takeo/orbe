import Foundation

/// 起動時の読み。形が合った後の値の読めなさは、その件だけに閉じ込める——定義が今の検証を通らない自動化は「定義を読めない」、
/// 中身の JSON を読めない回の記録は「不明な記録」、指す行や値が読めない候補は「読めない候補」として残し、ほかは普段どおり読む。
/// 読みの SQL の失敗は投げる（そのセッションは書かない）。
extension AutomationDatabase {
  static func memory(_ db: SQLiteDatabase, now: Date) throws -> AutomationMemory {
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
    var memory = AutomationMemory(
      automations: automations, unreadable: unreadable, proposals: proposals,
      unreadableProposals: unreadableProposals, judgeOwners: try database.judgeOwners())
    for automation in automations { try memory.recount(automation.id, database, now: now) }
    return memory
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

  /// 自動化 1 つを、部品・つながり・使う動作の定義の行から外の形の型に組み、検証に通す。組めないか通らなければ定義を読めない
  /// 自動化。
  private func automation(_ row: AutomationRow) throws -> Assembled {
    let rows = try nodeRows(of: row.id)
    let notify = row.notify.flatMap(AutomationNotify.init)
    func broken(_ reason: String, _ definition: Any) -> Assembled {
      .unreadable(
        AutomationUnreadable(
          id: row.id, name: try? TaskStore.validTitle(row.name), version: row.version,
          definition: Self.jsonText(definition), reason: reason, nodeIds: rows.map(\.id)))
    }
    let keys = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.key) })
    var definitionNodes: [AutomationDefinition.Node] = []
    for (index, nodeRow) in rows.enumerated() {
      switch Self.definitionNode(nodeRow, at: index, keys: keys) {
      case .success(let typed): definitionNodes.append(typed)
      case .failure(let problem): return broken(problem.reason, Self.rawDefinition(row, rows, keys))
      }
    }
    let definition = AutomationDefinition(name: row.name, notify: notify, parts: definitionNodes)
    let checked: (name: String, checkedNodes: [AutomationGraph.Checked])
    do throws(AutomationError) {
      checked = try definition.checked()
    } catch {
      return broken(Self.reason(error), AutomationWire.object(definition))
    }
    let graph = AutomationGraph(
      checked.checkedNodes,
      entities: zip(checked.checkedNodes, rows).map { checked, row in
        AutomationNode(checked.definitionNode, id: row.id, defId: row.defId)
      })
    var states: [AutomationNodeID: AutomationNodeState] = [:]
    for nodeRow in rows { states[nodeRow.id] = try state(of: nodeRow.id) }
    return .readable(
      Automation(
        id: row.id, name: checked.name, notify: notify, graph: graph,
        pausedAt: row.pausedAt.map(AutomationPersistence.date), version: row.version,
        createdAt: AutomationPersistence.date(row.createdAt), states: states))
  }

  /// 自動化の外していない部品の行（保存したままの値）。
  private struct NodeRow {
    let id: AutomationNodeID
    let defId: AutomationNodeDefID
    let key: String
    let name: String
    let trigger: String?
    let maxItems: Int?
    /// 組み合わせの定義を指すか。
    let composite: Bool
    let action: String?
    /// 入力（上流の部品・取り方・古さの上限。`from` の順）。
    let inputs: [AutomationNodeEdge]
  }

  /// 部品を型に組めなかった理由（定義の中の場所で言う英文）。
  private struct Unbuilt: Error {
    let reason: String
  }

  private func nodeRows(of automation: Int) throws -> [NodeRow] {
    try db.select(
      """
      SELECT p.id, p.key, p.name, p.trigger, p.max_items, p.def_id, d.kind, a.action
      FROM parts p JOIN part_defs d ON d.id = p.def_id LEFT JOIN action_defs a ON a.id = p.def_id
      WHERE p.automation_id = ? AND p.removed_at IS NULL ORDER BY p.position
      """, [.integer(Int64(automation))]
    ) { s in
      (
        id: AutomationNodeID(s.int(at: 0)), key: s.text(at: 1) ?? "", name: s.text(at: 2) ?? "",
        trigger: s.text(at: 3), maxItems: s.optionalInt64(at: 4).map(Int.init),
        defId: AutomationNodeDefID(s.int(at: 5)), composite: s.text(at: 6) == "composite",
        action: s.text(at: 7)
      )
    }.map { row in
      NodeRow(
        id: row.id, defId: row.defId, key: row.key, name: row.name, trigger: row.trigger,
        maxItems: row.maxItems, composite: row.composite, action: row.action,
        inputs: try db.select(
          """
          SELECT from_part_id, take, max_age_hours FROM part_edges WHERE to_part_id = ?
          ORDER BY position
          """, [.integer(Int64(row.id.rawValue))]
        ) { s in
          AutomationNodeEdge(
            from: AutomationNodeID(s.int(at: 0)),
            take: AutomationTake(rawValue: s.text(at: 1) ?? "") ?? .new,
            maxAgeHours: s.optionalInt64(at: 2).map(Int.init))
        })
    }
  }

  /// 部品の行を外の形の部品に組む。予定と動作の定義は保存した JSON をそれぞれの型で読み、入力の上流はこの自動化の今の鍵に
  /// 解く。読めなければ定義の中の場所で言う理由。
  private static func definitionNode(
    _ row: NodeRow, at index: Int, keys: [AutomationNodeID: String]
  ) -> Result<AutomationDefinition.Node, Unbuilt> {
    let at = "parts[\(index)]"
    guard let storedTrigger = row.trigger.flatMap(jsonObject) else {
      return .failure(Unbuilt(reason: "\(at).trigger: the stored trigger cannot be read"))
    }
    guard !row.composite else {
      return .failure(
        Unbuilt(
          reason: "\(at): the stored definition is made of parts, which this database version "
            + "does not hold"))
    }
    guard let storedAction = row.action.flatMap(jsonObject) else {
      return .failure(Unbuilt(reason: "\(at): the stored action cannot be read"))
    }
    let trigger: AutomationNode.Trigger
    let action: AutomationActionDef
    do throws(Unbuilt) {
      trigger = try decode(AutomationNode.Trigger.self, storedTrigger, at: "\(at).trigger")
      action = try decode(AutomationActionDef.self, storedAction, at: at)
    } catch {
      return .failure(error)
    }
    return .success(
      AutomationDefinition.Node(
        id: row.id, key: row.key, name: row.name, trigger: trigger,
        from: row.inputs.map {
          AutomationDefinition.Input(
            part: keys[$0.from] ?? "", take: $0.take, maxAgeHours: $0.maxAgeHours)
        }, action: action, maxItems: row.maxItems))
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any], at: String)
    throws(Unbuilt) -> T
  {
    do {
      return try AutomationWire.decoder.decode(
        type, from: try JSONSerialization.data(withJSONObject: object))
    } catch {
      throw Unbuilt(reason: AutomationDefinition.reason(error, at: at))
    }
  }

  /// 型に組めない自動化の外の形（AI が直すため）。行の生の値から組み、読めない値は読めた分だけを置く。
  private static func rawDefinition(
    _ row: AutomationRow, _ nodeRows: [NodeRow], _ keys: [AutomationNodeID: String]
  ) -> [String: Any] {
    var object: [String: Any] = [
      "name": row.name,
      "parts": nodeRows.map { nodeRow -> [String: Any] in
        var object: [String: Any] = [
          "id": nodeRow.id.rawValue, "key": nodeRow.key, "name": nodeRow.name,
        ]
        if let trigger = nodeRow.trigger.flatMap(jsonObject) { object["trigger"] = trigger }
        if let maxItems = nodeRow.maxItems { object["maxItems"] = maxItems }
        let from = nodeRow.inputs.map { edge -> Any in
          let key = keys[edge.from] ?? ""
          guard edge.take != .new || edge.maxAgeHours != nil else { return key }
          var input: [String: Any] = ["part": key]
          if edge.take != .new { input["take"] = edge.take.rawValue }
          if let hours = edge.maxAgeHours { input["maxAgeHours"] = hours }
          return input
        }
        if !from.isEmpty { object["from"] = from }
        if !nodeRow.composite, let action = nodeRow.action.flatMap(jsonObject) {
          object.merge(action) { current, _ in current }
        }
        return object
      },
    ]
    if let notify = row.notify { object["notify"] = notify }
    return object
  }

  /// 覚えている候補。指す行や値が読めない候補は、リンクだけを持つ読めない候補にする。
  private func heldProposals() throws -> ([AutomationProposal], [AutomationUnreadableProposal]) {
    let rows = try db.select(
      """
      SELECT q.id, q.run_id, r.part_id, r.def_id, r.ended_at, q.origin_version_id,
        q.origin_event_id, coalesce(v.body, e.body), coalesce(i.part_id, e.part_id), q.link, q.title,
        q.due, q.workspace, q.reason, h.resolved_at, s.outcome, s.task_id
      FROM held_proposals h JOIN proposals q ON q.id = h.proposal_id
      JOIN runs r ON r.id = q.run_id
      LEFT JOIN item_versions v ON v.id = q.origin_version_id
      LEFT JOIN items i ON i.id = v.item_id
      LEFT JOIN events e ON e.id = q.origin_event_id
      LEFT JOIN settlements s ON s.proposal_id = q.id
      ORDER BY q.id
      """, []
    ) { s in
      (
        id: s.int(at: 0), run: s.int(at: 1), judge: s.int(at: 2), defId: s.int(at: 3),
        endedAt: s.int64(at: 4), version: s.optionalInt64(at: 5), event: s.optionalInt64(at: 6),
        body: s.text(at: 7), originNodeId: s.optionalInt64(at: 8), link: s.text(at: 9) ?? "",
        title: s.text(at: 10) ?? "", due: s.text(at: 11), workspace: s.text(at: 12),
        reason: s.text(at: 13), resolvedAt: s.optionalInt64(at: 14), outcome: s.text(at: 15),
        taskId: s.optionalInt64(at: 16)
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
      guard let state, let origin, let originNodeId = row.originNodeId,
        let item = Self.decode(AutomationItem.self, row.body), item.link == row.link,
        due.map({ $0 != nil }) ?? true, workspace.map({ $0 != nil }) ?? true
      else {
        unreadable.append(
          AutomationUnreadableProposal(
            id: row.id, link: row.link, judge: AutomationNodeID(row.judge)))
        continue
      }
      proposals.append(
        AutomationProposal(
          id: row.id, runId: row.run,
          judge: AutomationNodeID(row.judge), defId: AutomationNodeDefID(row.defId),
          originNodeId: AutomationNodeID(Int(originNodeId)), origin: origin, item: item,
          title: row.title,
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
