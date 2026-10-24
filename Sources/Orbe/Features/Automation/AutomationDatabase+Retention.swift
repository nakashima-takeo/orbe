import Foundation

/// 走っている回が確定まで使うもの: 読んだ行とその出どころ（判定の確定は読んだ時点の出どころの版を指す）と、回を始めたときの
/// 部品の定義（確定の回の記録が指す）。
struct AutomationHolding: Equatable {
  var rows: Set<AutomationRowRef> = []
  var defs: Set<AutomationDefID> = []

  mutating func formUnion(_ other: Self) {
    rows.formUnion(other.rows)
    defs.formUnion(other.defs)
  }
}

/// 保持と掃除。確定・さばき・書き換えのトランザクションの最後に 1 度だけ、指されていない行を消す。どの参照元も `NOT EXISTS`
/// で見て、外部キーが参照の漏れをトランザクションの失敗にする。
extension AutomationDatabase {
  /// `holding` は走っている回が確定まで使うもの（消さない）。
  func sweep(now: Date, holding: AutomationHolding) throws {
    let heldVersions = holding.rows.compactMap { ref -> String? in
      if case .version(let id) = ref { return String(id) }
      return nil
    }.joined(separator: ",")
    let heldEvents = holding.rows.compactMap { ref -> String? in
      if case .event(let id) = ref { return String(id) }
      return nil
    }.joined(separator: ",")
    try sweepRecords()
    try sweepItems(heldVersions)
    try sweepEvents(now: now, held: heldEvents)
    try sweepLedger(held: holding.defs.map { String($0.rawValue) }.joined(separator: ","))
  }

  /// 判断の記録・候補・回の記録。
  private func sweepRecords() throws {
    let keep = Int64(AutomationPartState.retainedRuns)
    // 判断の記録: 判定の部品ごとに新しい方から回数まで。外した部品のものは残さない。どちらも覚えている候補のものは消さない。
    try db.run(
      """
      DELETE FROM settlements WHERE proposal_id IN (
        SELECT proposal_id FROM (
          SELECT s.proposal_id, p.removed_at, ROW_NUMBER() OVER (
            PARTITION BY r.part_id ORDER BY s.decided_at DESC, s.proposal_id DESC) AS n
          FROM settlements s JOIN proposals q ON q.id = s.proposal_id JOIN runs r ON r.id = q.run_id
            JOIN parts p ON p.id = r.part_id)
        WHERE (n > ?1 OR removed_at IS NOT NULL)
          AND proposal_id NOT IN (SELECT proposal_id FROM held_proposals))
      """, [.integer(keep)])
    // 判断が無く、覚えてもいない候補。
    try db.run(
      """
      DELETE FROM proposals WHERE id NOT IN (SELECT proposal_id FROM held_proposals)
        AND id NOT IN (SELECT proposal_id FROM settlements)
      """, [])
    // 回の記録: 部品ごとに新しい方から回数まで。外した部品のものは残さない。外していない部品の最新の成功した回・外した印の回・
    // 残っている候補を出した回は消さない（最新の回は回数の内にいつも入る）。
    try db.run(
      """
      DELETE FROM runs WHERE id IN (
        SELECT id FROM (
          SELECT r.id, p.removed_at, ROW_NUMBER() OVER (PARTITION BY r.part_id ORDER BY r.id DESC) AS n
          FROM runs r JOIN parts p ON p.id = r.part_id)
        WHERE (n > ?1 OR removed_at IS NOT NULL)
          AND id NOT IN (SELECT breach_run_id FROM parts WHERE breach_run_id IS NOT NULL)
          AND id NOT IN (SELECT run_id FROM proposals)
          AND id NOT IN (
            SELECT max(r.id) FROM runs r JOIN parts p ON p.id = r.part_id
            WHERE r.failure IS NULL AND p.removed_at IS NULL GROUP BY r.part_id))
      """, [.integer(keep)])
  }

  /// 出来事: 残す期間を過ぎ、どこからも指されていないもの。
  private func sweepEvents(now: Date, held heldEvents: String) throws {
    try db.run(
      """
      DELETE FROM events WHERE created_at < ?1
        \(heldEvents.isEmpty ? "" : "AND id NOT IN (\(heldEvents))")
        AND NOT EXISTS (SELECT 1 FROM items WHERE source_event_id = events.id)
        AND NOT EXISTS (SELECT 1 FROM events e WHERE e.source_event_id = events.id)
        AND NOT EXISTS (SELECT 1 FROM run_event_inputs WHERE event_id = events.id)
        AND NOT EXISTS (SELECT 1 FROM proposals WHERE origin_event_id = events.id)
      """, [Self.cutoff(now)])
  }

  /// 外した部品の台帳と部品の定義: どこからも指されず、走っている回も使っていないもの。
  private func sweepLedger(held heldDefs: String) throws {
    try db.run(
      """
      DELETE FROM parts WHERE removed_at IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM runs WHERE part_id = parts.id)
        AND NOT EXISTS (SELECT 1 FROM items WHERE part_id = parts.id)
        AND NOT EXISTS (SELECT 1 FROM events WHERE part_id = parts.id)
      """, [])
    // 部品の定義: どこからも指されず、走っている回も使っていないもの。
    try db.run(
      """
      DELETE FROM action_defs WHERE NOT EXISTS (SELECT 1 FROM parts WHERE def_id = action_defs.id)
        AND NOT EXISTS (SELECT 1 FROM runs WHERE def_id = action_defs.id)
        AND NOT EXISTS (SELECT 1 FROM composite_slots WHERE child_def_id = action_defs.id)
        \(heldDefs.isEmpty ? "" : "AND id NOT IN (\(heldDefs))")
      """, [])
    try db.run(
      """
      DELETE FROM part_defs WHERE kind = 'action'
        AND NOT EXISTS (SELECT 1 FROM action_defs WHERE id = part_defs.id)
      """, [])
  }

  /// 今の集合の項目と版。今有効な項目の今の版は消さない。基準は出す側の部品の残す数の内で最も古い回の始まり（残す数を
  /// 過ぎても例外として残る回は数えない——その回が読んだ版は回の履歴が指して残る）。版は、どこからも指されず、次の版が基準より
  /// 前に出ているものを消す。項目は、基準より前に無効になり、引き継ぎに指されず、版が 1 つも指されていないものを版ごと消す。
  private func sweepItems(_ heldVersions: String) throws {
    let oldest = """
      coalesce((
        SELECT min(started_at) FROM (
          SELECT started_at, ROW_NUMBER() OVER (ORDER BY id DESC) AS n FROM runs
          WHERE part_id = i.part_id)
        WHERE n <= \(AutomationPartState.retainedRuns)), 9223372036854775807)
      """
    let referenced = """
      (v.id IN (SELECT version_id FROM run_item_inputs)
        OR v.id IN (SELECT origin_version_id FROM proposals WHERE origin_version_id IS NOT NULL)
        \(heldVersions.isEmpty ? "" : "OR v.id IN (\(heldVersions))"))
      """
    try db.run(
      """
      DELETE FROM item_versions WHERE id IN (
        SELECT v.id FROM item_versions v JOIN items i ON i.id = v.item_id
        WHERE NOT \(referenced)
          AND EXISTS (
            SELECT 1 FROM item_versions n WHERE n.item_id = v.item_id AND n.id > v.id
              AND n.valid_from < \(oldest)))
      """, [])
    let gone = try db.select(
      """
      SELECT i.id FROM items i
      WHERE i.valid_to IS NOT NULL AND i.valid_to < \(oldest)
        AND NOT EXISTS (SELECT 1 FROM items s WHERE s.source_item_id = i.id)
        AND NOT EXISTS (SELECT 1 FROM events s WHERE s.source_item_id = i.id)
        AND NOT EXISTS (SELECT 1 FROM item_versions v WHERE v.item_id = i.id AND \(referenced))
      """, []
    ) { $0.int64(at: 0) }
    for id in gone {
      try db.run("DELETE FROM item_versions WHERE item_id = ?", [.integer(id)])
      try db.run("DELETE FROM items WHERE id = ?", [.integer(id)])
    }
  }
}
