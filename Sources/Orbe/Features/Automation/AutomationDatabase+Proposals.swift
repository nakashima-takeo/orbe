import Foundation

/// 候補（判定が出したデータ）・覚えている印・人の判断。
extension AutomationDatabase {
  /// 判定の回が出した候補を足し、覚えている印を付けて ID を返す。
  func insert(
    proposal: AutomationNodePass.Proposal, run: Int
  ) throws -> Int {
    var origin: [SQLiteValue] = [.null, .null]
    switch proposal.origin.row {
    case .version(let id): origin[0] = .integer(Int64(id))
    case .event(let id): origin[1] = .integer(Int64(id))
    }
    try db.run(
      """
      INSERT INTO proposals (run_id, origin_version_id, origin_event_id, link, title, due, workspace,
        reason)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [.integer(Int64(run))] + origin + [
        .text(proposal.origin.item.link), .text(proposal.title), Self.text(proposal.due?.text),
        Self.text(proposal.workspace?.uuidString), Self.text(proposal.reason),
      ])
    let id = db.lastInsertRowID
    try db.run(
      "INSERT INTO held_proposals (proposal_id, link) VALUES (?, ?)",
      [.integer(id), .text(proposal.origin.item.link)])
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

  /// 覚えている候補を出した判定のノードの持ち主（ノード ID → 自動化 ID）。外したノードも、候補の回に指されている間は台帳が残って
  /// 持ち主を指す。持ち主の自動化を消したノードは入らない。
  func judgeOwners() throws -> [AutomationNodeID: Int] {
    Dictionary(
      uniqueKeysWithValues: try db.select(
        """
        SELECT DISTINCT r.node_id, n.automation_id FROM held_proposals h
        JOIN proposals q ON q.id = h.proposal_id JOIN runs r ON r.id = q.run_id
        JOIN nodes n ON n.id = r.node_id WHERE n.automation_id IS NOT NULL
        """, []
      ) { (AutomationNodeID($0.int(at: 0)), $0.int(at: 1)) })
  }
}
