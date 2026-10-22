import Foundation

/// 自動化の DB の読み書き。書く手はどれもトランザクションの中で呼ぶ（`transaction`）。
///
/// 部品の定義（`part_defs` 以下）は書き換えずに足し、自動化・部品・つながりの行は書き換える。出す側のデータは性質ごとに、
/// 今の集合（`items`・`item_versions`）と出来事の流れ（`events`）に分け、受け手はつながりに読んだ位置を持つ。参照は外部キーで
/// 守り、指されなくなった行はトランザクションの最後の掃除が消す（`AutomationDatabase+Retention`）。
final class AutomationDatabase {
  struct Opened {
    let database: AutomationDatabase
    let snapshot: AutomationSnapshot
  }

  let db: SQLiteDatabase

  init(_ db: SQLiteDatabase) {
    self.db = db
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    try db.transaction(body)
  }

  /// この DB を `copy` へ写すバックアップ（`SQLiteBackup`）。
  func backup(into copy: SQLiteDatabase) throws -> SQLiteBackup {
    try SQLiteBackup(from: db, to: copy)
  }

  // MARK: - 自動化

  func insertAutomation(name: String, notify: AutomationNotify?, createdAt: Date) throws -> Int {
    try db.run(
      "INSERT INTO automations (name, notify, version, created_at) VALUES (?, ?, 1, ?)",
      [.text(name), Self.text(notify?.rawValue), Self.instant(createdAt)])
    return Int(db.lastInsertRowID)
  }

  func updateAutomation(_ id: Int, name: String, notify: AutomationNotify?, version: Int) throws {
    try db.run(
      "UPDATE automations SET name = ?, notify = ?, version = ? WHERE id = ?",
      [.text(name), Self.text(notify?.rawValue), .integer(Int64(version)), .integer(Int64(id))])
  }

  func setPaused(_ id: Int, at: Date?) throws {
    try db.run(
      "UPDATE automations SET paused_at = ? WHERE id = ?",
      [at.map(Self.instant) ?? .null, .integer(Int64(id))])
  }

  /// 自動化の止めた時刻と作った時刻。
  func automationRow(_ id: Int) throws -> (pausedAt: Date?, createdAt: Date) {
    try db.select(
      "SELECT paused_at, created_at FROM automations WHERE id = ?", [.integer(Int64(id))]
    ) {
      (
        pausedAt: $0.optionalInt64(at: 0).map(AutomationPersistence.date),
        createdAt: AutomationPersistence.date($0.int64(at: 1))
      )
    }.first ?? (nil, Date(timeIntervalSince1970: 0))
  }

  /// 自動化の行を消す。部品は先に外しておく（外した部品の台帳は自動化を指さなくなる）。
  func deleteAutomation(_ id: Int) throws {
    try db.run("DELETE FROM automations WHERE id = ?", [.integer(Int64(id))])
  }

  // MARK: - 部品の定義

  /// 動作の定義を足して ID を返す。
  func insert(action: AutomationActionDef) throws -> AutomationDefID {
    try db.run("INSERT INTO part_defs (kind) VALUES ('action')", [])
    let id = db.lastInsertRowID
    try db.run(
      "INSERT INTO action_defs (id, action) VALUES (?, ?)",
      [.integer(id), .text(try Self.encode(action))])
    return AutomationDefID(Int(id))
  }

  // MARK: - 部品

  /// 部品を足して ID を返す。
  func insertPart(
    of automation: Int, at position: Int, _ part: AutomationDefinition.Part,
    defId: AutomationDefID, addedAt: Date
  ) throws -> AutomationPartID {
    try db.run(
      """
      INSERT INTO parts (automation_id, position, key, name, trigger, max_items, def_id, added_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .integer(Int64(automation)), .integer(Int64(position)), .text(part.key), .text(part.name),
        .text(try Self.encode(part.trigger)), part.maxItems.map { .integer(Int64($0)) } ?? .null,
        .integer(Int64(defId.rawValue)), Self.instant(addedAt),
      ])
    return AutomationPartID(Int(db.lastInsertRowID))
  }

  /// 外していない部品の位置と鍵を、一意に当たらない仮の値へ退ける（入れ替えを 1 行ずつ書くため）。
  func setAsidePlaces(of automation: Int) throws {
    try db.run(
      """
      UPDATE parts SET position = -id, key = char(0) || id
      WHERE automation_id = ? AND removed_at IS NULL
      """, [.integer(Int64(automation))])
  }

  func updatePart(
    _ id: AutomationPartID, at position: Int, _ part: AutomationDefinition.Part,
    defId: AutomationDefID
  ) throws {
    try db.run(
      """
      UPDATE parts SET position = ?, key = ?, name = ?, trigger = ?, max_items = ?, def_id = ?
      WHERE id = ?
      """,
      [
        .integer(Int64(position)), .text(part.key), .text(part.name),
        .text(try Self.encode(part.trigger)), part.maxItems.map { .integer(Int64($0)) } ?? .null,
        .integer(Int64(defId.rawValue)), .integer(Int64(id.rawValue)),
      ])
  }

  /// 部品を外す: 外した時刻を書き、今有効な項目を無効にし、つながりと外した印と持ち越しを消し、回の記録（残っている候補を
  /// 出した回を除く）と、判定だった部品の判断の記録（覚えている候補のものを除く）を消す。指されなくなった台帳は掃除が消す。
  func removePart(_ id: AutomationPartID, at: Date) throws {
    let part: [SQLiteValue] = [.integer(Int64(id.rawValue))]
    try invalidateItems(of: id, at: at)
    try db.run("DELETE FROM part_edges WHERE from_part_id = ?1 OR to_part_id = ?1", part)
    try db.run(
      "UPDATE parts SET removed_at = ?, breach_run_id = NULL, pending_drops = '{}' WHERE id = ?",
      [Self.instant(at)] + part)
    try db.run(
      """
      DELETE FROM settlements WHERE proposal_id IN (
        SELECT q.id FROM proposals q JOIN runs r ON r.id = q.run_id
        WHERE r.part_id = ? AND q.id NOT IN (SELECT proposal_id FROM held_proposals))
      """, part)
    try db.run(
      """
      DELETE FROM proposals WHERE run_id IN (SELECT id FROM runs WHERE part_id = ?)
        AND id NOT IN (SELECT proposal_id FROM held_proposals)
        AND id NOT IN (SELECT proposal_id FROM settlements)
      """, part)
    try db.run(
      "DELETE FROM runs WHERE part_id = ? AND id NOT IN (SELECT run_id FROM proposals)", part)
  }

  /// 外した印の回。
  func setBreach(_ id: AutomationPartID, run: Int?) throws {
    try db.run(
      "UPDATE parts SET breach_run_id = ? WHERE id = ?",
      [run.map { .integer(Int64($0)) } ?? .null, .integer(Int64(id.rawValue))])
  }

  func setPendingDrops(_ id: AutomationPartID, _ drops: AutomationDrops) throws {
    try db.run(
      "UPDATE parts SET pending_drops = ? WHERE id = ?",
      [.text(try Self.encode(drops)), .integer(Int64(id.rawValue))])
  }

  // MARK: - つながり

  /// 受け手のつながりを `inputs` に置き換える。同じ部品どうしのつながりが残れば読んだ位置も残り、新しいつながりは項目を 0、
  /// 出来事を上流の最後の出来事の番号から読む。
  func setEdges(of automation: Int, to receiver: AutomationPartID, _ inputs: [AutomationPartEdge])
    throws
  {
    let to = Int64(receiver.rawValue)
    let kept = Dictionary(
      uniqueKeysWithValues: try db.select(
        "SELECT from_part_id, read_item_seq, read_event_seq FROM part_edges WHERE to_part_id = ?",
        [.integer(to)]
      ) { ($0.int(at: 0), ($0.int64(at: 1), $0.int64(at: 2))) })
    try db.run("DELETE FROM part_edges WHERE to_part_id = ?", [.integer(to)])
    for (position, edge) in inputs.enumerated() {
      let from = Int64(edge.from.rawValue)
      let start =
        try db.select(
          "SELECT last_event_seq FROM parts WHERE id = ?", [.integer(from)]
        ) { $0.int64(at: 0) }.first ?? 0
      let read = kept[edge.from.rawValue] ?? (0, start)
      try db.run(
        """
        INSERT INTO part_edges (automation_id, from_part_id, to_part_id, position, take,
          max_age_hours, read_item_seq, read_event_seq)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          .integer(Int64(automation)), .integer(from), .integer(to), .integer(Int64(position)),
          .text(edge.take.rawValue), edge.maxAgeHours.map { .integer(Int64($0)) } ?? .null,
          .integer(read.0), .integer(read.1),
        ])
    }
  }

  // MARK: - 値

  static func instant(_ date: Date) -> SQLiteValue {
    .integer(AutomationPersistence.millis(date))
  }

  static func text(_ text: String?) -> SQLiteValue {
    text.map { .text($0) } ?? .null
  }

  static func encode(_ value: some Encodable) throws -> String {
    let data = try AutomationWire.encoder().encode(value)
    guard let text = String(bytes: data, encoding: .utf8) else {
      throw EncodingError.invalidValue(
        value, .init(codingPath: [], debugDescription: "JSON is not UTF-8"))
    }
    return text
  }

  static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
    text.flatMap { try? AutomationWire.decoder.decode(type, from: Data($0.utf8)) }
  }
}

/// 出す側の行への参照（回の履歴・候補の出どころ）。項目は版を指す。
enum AutomationRowRef: Hashable {
  case version(Int)
  case event(Int)
}

/// 引き継いだ入力（項目か出来事）。版ではなく項目を指す——入力の中身が変わっただけで別の入力にならないように。
enum AutomationSourceRef: Hashable {
  case item(Int)
  case event(Int)
}
