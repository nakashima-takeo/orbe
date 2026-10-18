import Foundation

/// 起動時の読み。
extension AutomationDatabase {
  /// 全部を読む。今の形として読めない行（定義がグラフの検証を通らない・部品の状態がグラフの部品と揃わない・JSON が読めない）が
  /// あれば nil——Orbe が書いたのではない DB として退避させる。
  static func snapshot(_ db: SQLiteDatabase) throws -> AutomationSnapshot? {
    var automations: [Automation] = []
    var indexOf: [Int: Int] = [:]
    for row in try db.select(
      "SELECT id, definition, paused, created_at, accepted, dismissed FROM automations ORDER BY id",
      [],
      {
        (
          $0.int(at: 0), $0.text(at: 1), $0.int(at: 2), $0.int64(at: 3), $0.int(at: 4),
          $0.int(at: 5)
        )
      })
    {
      guard let definition = decode(AutomationDefinition.self, row.1),
        let checked = try? definition.checked(), checked.name == definition.name,
        checked.graph.parts == definition.parts
      else { return nil }
      indexOf[row.0] = automations.count
      automations.append(
        Automation(
          id: row.0, name: checked.name, notify: definition.notify, graph: checked.graph,
          paused: row.2 != 0,
          createdAt: AutomationPersistence.date(row.3),
          tally: AutomationTally(accepted: row.4, dismissed: row.5), parts: [:]))
    }
    guard try readParts(db, &automations, indexOf), try readRuns(db, &automations, indexOf),
      try readInbox(db, &automations, indexOf),
      automations.allSatisfy({ Set($0.parts.keys) == Set($0.graph.nodes.map(\.key)) }),
      let proposals = try readProposals(db)
    else { return nil }
    return AutomationSnapshot(automations: automations, proposals: proposals)
  }

  private static func readParts(
    _ db: SQLiteDatabase, _ automations: inout [Automation], _ indexOf: [Int: Int]
  ) throws -> Bool {
    let rows = try db.select(
      """
      SELECT automation_id, key, added_at, last_run_at, succeeded_at, pending_drops, last_output, breach
      FROM parts
      """, []
    ) { s in
      (
        s.int(at: 0), s.text(at: 1) ?? "", s.int64(at: 2), s.optionalInt64(at: 3),
        s.optionalInt64(at: 4),
        s.text(at: 5), s.text(at: 6), s.text(at: 7)
      )
    }
    for row in rows {
      guard let index = indexOf[row.0], automations[index].graph.node(row.1) != nil,
        let drops = decode(AutomationDrops.self, row.5),
        let lastOutput = decode([AutomationSeen].self, row.6)
      else { return false }
      var breach: AutomationBreachMark?
      if let raw = row.7 {
        guard let mark = decode(AutomationBreachMark.self, raw) else { return false }
        breach = mark
      }
      automations[index].parts[row.1] = AutomationPartState(
        addedAt: AutomationPersistence.date(row.2),
        lastRunAt: row.3.map(AutomationPersistence.date),
        succeededAt: row.4.map(AutomationPersistence.date), lastOutput: lastOutput,
        pendingDrops: drops, breach: breach)
    }
    return true
  }

  private static func readRuns(
    _ db: SQLiteDatabase, _ automations: inout [Automation], _ indexOf: [Int: Int]
  ) throws -> Bool {
    let rows = try db.select(
      "SELECT automation_id, part_key, record FROM runs ORDER BY started_at DESC, rowid DESC", []
    ) { ($0.int(at: 0), $0.text(at: 1) ?? "", $0.text(at: 2)) }
    for row in rows {
      guard let index = indexOf[row.0], automations[index].parts[row.1] != nil,
        let run = decode(AutomationPartRun.self, row.2)
      else { return false }
      automations[index].parts[row.1]?.runs.append(run)
    }
    return true
  }

  private static func readInbox(
    _ db: SQLiteDatabase, _ automations: inout [Automation], _ indexOf: [Int: Int]
  ) throws -> Bool {
    let rows = try db.select(
      "SELECT automation_id, part_key, count(*), max(seq) FROM inbox GROUP BY automation_id, part_key",
      []
    ) { ($0.int(at: 0), $0.text(at: 1) ?? "", $0.int(at: 2), $0.int(at: 3)) }
    for row in rows {
      guard let index = indexOf[row.0], automations[index].parts[row.1] != nil else { return false }
      automations[index].parts[row.1]?.inbox = row.2
      automations[index].parts[row.1]?.newestSeq = row.3
    }
    return true
  }

  private static func readProposals(_ db: SQLiteDatabase) throws -> [AutomationProposal]? {
    let rows = try db.select(
      """
      SELECT id, state, task_id, automation_id, part_key, source_part_key, title, due, workspace,
        proposed_at, item, reason
      FROM proposals ORDER BY id
      """, []
    ) { s in
      (
        s.int(at: 0), s.text(at: 1) ?? "", s.optionalInt64(at: 2), s.int(at: 3),
        s.text(at: 4) ?? "",
        s.text(at: 5) ?? "", s.text(at: 6) ?? "", s.text(at: 7), s.text(at: 8), s.int64(at: 9),
        s.text(at: 10), s.text(at: 11)
      )
    }
    var proposals: [AutomationProposal] = []
    for row in rows {
      guard let item = decode(AutomationItem.self, row.10) else { return nil }
      let state: AutomationProposal.State
      switch (row.1, row.2) {
      case ("open", nil): state = .open
      case ("accepted", let taskId?): state = .accepted(taskId: Int(taskId))
      case ("dismissed", nil): state = .dismissed
      case ("resolved", nil): state = .resolved
      default: return nil
      }
      var due: TaskItem.DueDate?
      if let raw = row.7 {
        guard let parsed = TaskItem.DueDate(raw) else { return nil }
        due = parsed
      }
      var workspace: UUID?
      if let raw = row.8 {
        guard let parsed = UUID(uuidString: raw) else { return nil }
        workspace = parsed
      }
      proposals.append(
        AutomationProposal(
          id: row.0, automationId: row.3, partKey: row.4, sourcePartKey: row.5, item: item,
          title: row.6, due: due, workspace: workspace, reason: row.11,
          proposedAt: AutomationPersistence.date(row.9), state: state))
    }
    return proposals
  }
}
