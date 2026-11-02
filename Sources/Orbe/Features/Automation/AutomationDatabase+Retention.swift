import Foundation

/// 走っている回が確定まで使うもの: 読んだ行（回の履歴と、判定の確定の候補が指す）と、回を始めたときのノードの定義（確定の回の
/// 記録が指す）。
struct AutomationHolding: Equatable {
  var rows: Set<AutomationRowRef> = []
  var defs: Set<AutomationNodeDefID> = []

  mutating func formUnion(_ other: Self) {
    rows.formUnion(other.rows)
    defs.formUnion(other.defs)
  }
}

/// 保持と掃除。確定・さばき・書き換えのトランザクションの最後に 1 度だけ、指されていない行を消す。どの参照元も `NOT EXISTS`
/// で見て、外部キーが参照の漏れをトランザクションの失敗にする。残す数と期間は、掃除のたびに読む今の保持の値
/// （`AutomationRetention`）と、出す側のノードの `retention_days` が決める。
extension AutomationDatabase {
  /// `holding` は走っている回が確定まで使うもの（消さない）。回の記録を消した外していないノードを返す（呼び手がメモリの直近の
  /// 回を読み直す——保持の回数がメモリの直近の数より小さいと、メモリに DB で消えた回が残るため）。
  @discardableResult func sweep(now: Date, holding: AutomationHolding) throws -> Set<
    AutomationNodeID
  > {
    let retention = retention()
    let heldVersions = holding.rows.compactMap { ref -> String? in
      if case .version(let id) = ref { return String(id) }
      return nil
    }.joined(separator: ",")
    let heldEvents = holding.rows.compactMap { ref -> String? in
      if case .event(let id) = ref { return String(id) }
      return nil
    }.joined(separator: ",")
    let kept = Kept(
      count: retention.runCount,
      since: now.addingTimeInterval(-TimeInterval(retention.runDays) * Self.day))
    let swept = try sweepRecords(kept)
    try sweepItems(heldVersions, kept)
    try sweepEvents(now: now, held: heldEvents)
    try sweepLedger(held: holding.defs.map { String($0.rawValue) }.joined(separator: ","))
    return swept
  }

  /// 残す記録: ノードごとに新しい方から `count` 件か、`since` 以降のもの。
  private struct Kept {
    let count: Int
    let since: Date

    var values: [SQLiteValue] { [.integer(Int64(count)), AutomationDatabase.instant(since)] }
  }

  /// 判断の記録・候補・回の記録。回の記録を消した外していないノードを返す。
  private func sweepRecords(_ kept: Kept) throws -> Set<AutomationNodeID> {
    // 判断の記録: 判定のノードごとに、新しい方から回数の内か期間の内（判断の時刻で見る）のものを残す。外したノードのものは
    // 残さない。どちらも覚えている候補のものは消さない。
    try db.run(
      """
      DELETE FROM settlements WHERE proposal_id IN (
        SELECT proposal_id FROM (
          SELECT s.proposal_id, s.decided_at, o.removed_at, ROW_NUMBER() OVER (
            PARTITION BY q.node_id ORDER BY s.decided_at DESC, s.proposal_id DESC) AS n
          FROM settlements s JOIN proposals q ON q.id = s.proposal_id JOIN nodes o ON o.id = q.node_id)
        WHERE ((n > ?1 AND decided_at < ?2) OR removed_at IS NOT NULL)
          AND proposal_id NOT IN (SELECT proposal_id FROM held_proposals))
      """, kept.values)
    // 判断が無く、覚えてもいない候補。
    try db.run(
      """
      DELETE FROM proposals WHERE id NOT IN (SELECT proposal_id FROM held_proposals)
        AND id NOT IN (SELECT proposal_id FROM settlements)
      """, [])
    // 回の記録: ノードごとに、新しい方から回数の内か期間の内（始まりの時刻で見る）のものを残す。外したノードのものは残さない。
    // 外していないノードの最新の成功した回・外した印の回・残っている候補を出した回は消さない（最新の回は回数の内にいつも入る）。
    let stale = """
      SELECT id FROM (
        SELECT r.id, r.started_at, o.removed_at,
          ROW_NUMBER() OVER (PARTITION BY r.node_id ORDER BY r.id DESC) AS n
        FROM runs r JOIN nodes o ON o.id = r.node_id)
      WHERE ((n > ?1 AND started_at < ?2) OR removed_at IS NOT NULL)
        AND id NOT IN (SELECT breach_run_id FROM nodes WHERE breach_run_id IS NOT NULL)
        AND id NOT IN (SELECT run_id FROM proposals)
        AND id NOT IN (
          SELECT max(r.id) FROM runs r JOIN nodes o ON o.id = r.node_id
          WHERE r.failure IS NULL AND o.removed_at IS NULL GROUP BY r.node_id)
      """
    let swept = try db.select(
      """
      SELECT DISTINCT r.node_id FROM runs r JOIN nodes o ON o.id = r.node_id
      WHERE o.removed_at IS NULL AND r.id IN (\(stale))
      """, kept.values
    ) { AutomationNodeID($0.int(at: 0)) }
    try db.run("DELETE FROM runs WHERE id IN (\(stale))", kept.values)
    return Set(swept)
  }

  /// 出来事: 出したノードの残す期間を過ぎ、どこからも指されていないもの。
  private func sweepEvents(now: Date, held heldEvents: String) throws {
    let expired = expiredEvents(at: now)
    try db.run(
      """
      DELETE FROM events WHERE id IN (\(expired.sql))
        \(heldEvents.isEmpty ? "" : "AND id NOT IN (\(heldEvents))")
        AND NOT EXISTS (SELECT 1 FROM items WHERE source_event_id = events.id)
        AND NOT EXISTS (SELECT 1 FROM events e WHERE e.source_event_id = events.id)
        AND NOT EXISTS (SELECT 1 FROM run_event_inputs WHERE event_id = events.id)
        AND NOT EXISTS (SELECT 1 FROM proposals WHERE event_id = events.id)
      """, expired.values)
  }

  /// 外したノードの台帳とノードの定義: どこからも指されず、走っている回も使っていないもの。
  private func sweepLedger(held heldDefs: String) throws {
    try db.run(
      """
      DELETE FROM nodes WHERE removed_at IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM runs WHERE node_id = nodes.id)
        AND NOT EXISTS (SELECT 1 FROM items WHERE node_id = nodes.id)
        AND NOT EXISTS (SELECT 1 FROM events WHERE node_id = nodes.id)
      """, [])
    // ノードの定義: どこからも指されず、走っている回も使っていないもの。
    try db.run(
      """
      DELETE FROM action_defs WHERE NOT EXISTS (SELECT 1 FROM nodes WHERE def_id = action_defs.id)
        AND NOT EXISTS (SELECT 1 FROM runs WHERE def_id = action_defs.id)
        AND NOT EXISTS (SELECT 1 FROM composite_slots WHERE child_def_id = action_defs.id)
        \(heldDefs.isEmpty ? "" : "AND id NOT IN (\(heldDefs))")
      """, [])
    try db.run(
      """
      DELETE FROM node_defs WHERE kind = 'action'
        AND NOT EXISTS (SELECT 1 FROM action_defs WHERE id = node_defs.id)
      """, [])
  }

  /// 今の集合の項目と版。今有効な項目の今の版は消さない。基準は出す側のノードの、回の記録と同じ規則（回数の内か期間の内）で
  /// 残る回のうち最も古い始まり（例外として残る回は数えない——その回が読んだ版は回の履歴が指して残る）。版は、どこからも指されず、
  /// 次の版が基準より前に出ているものを消す。項目は、基準より前に無効になり、引き継ぎに指されず、版が 1 つも指されていないものを
  /// 版ごと消す。基準はノードごとに 1 度だけ求める（`MATERIALIZED`）——行ごとに回を数え直すと、回の数に比例して掃除が重くなる。
  private func sweepItems(_ heldVersions: String, _ kept: Kept) throws {
    let oldestByNode = """
      WITH oldest(node_id, at) AS MATERIALIZED (
        SELECT node_id, min(started_at) FROM (
          SELECT node_id, started_at,
            ROW_NUMBER() OVER (PARTITION BY node_id ORDER BY id DESC) AS n
          FROM runs)
        WHERE n <= ?1 OR started_at >= ?2 GROUP BY node_id)
      """
    let oldest = "coalesce((SELECT at FROM oldest WHERE node_id = i.node_id), 9223372036854775807)"
    let referenced = """
      (v.id IN (SELECT version_id FROM run_item_inputs)
        OR v.id IN (SELECT version_id FROM proposals WHERE version_id IS NOT NULL)
        \(heldVersions.isEmpty ? "" : "OR v.id IN (\(heldVersions))"))
      """
    try db.run(
      """
      \(oldestByNode)
      DELETE FROM item_versions WHERE id IN (
        SELECT v.id FROM item_versions v JOIN items i ON i.id = v.item_id
        WHERE NOT \(referenced)
          AND EXISTS (
            SELECT 1 FROM item_versions n WHERE n.item_id = v.item_id AND n.id > v.id
              AND n.valid_from < \(oldest)))
      """, kept.values)
    let gone = try db.select(
      """
      \(oldestByNode)
      SELECT i.id FROM items i
      WHERE i.valid_to IS NOT NULL AND i.valid_to < \(oldest)
        AND NOT EXISTS (SELECT 1 FROM items s WHERE s.source_item_id = i.id)
        AND NOT EXISTS (SELECT 1 FROM events s WHERE s.source_item_id = i.id)
        AND NOT EXISTS (SELECT 1 FROM item_versions v WHERE v.item_id = i.id AND \(referenced))
      """, kept.values
    ) { $0.int64(at: 0) }
    for id in gone {
      try db.run("DELETE FROM item_versions WHERE item_id = ?", [.integer(id)])
      try db.run("DELETE FROM items WHERE id = ?", [.integer(id)])
    }
  }
}
