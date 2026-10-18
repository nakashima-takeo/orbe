import Foundation

/// 自動化の DB の読み書き。書く手はどれもトランザクションの中で呼ぶ（`transaction`）。
final class AutomationDatabase {
  struct Opened {
    let database: AutomationDatabase
    let snapshot: AutomationSnapshot
  }

  private let db: SQLiteDatabase

  init(_ db: SQLiteDatabase) {
    self.db = db
  }

  /// ID（自動化・候補）と溜まりの通し番号は使い回さない（AUTOINCREMENT）——消した最大の番号が新しい行に再び付くと、その行を
  /// 取って走っている回の確定が、置き換わった新しい行を消す。
  static let schema = """
    CREATE TABLE automations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      definition TEXT NOT NULL,
      paused INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      accepted INTEGER NOT NULL,
      dismissed INTEGER NOT NULL
    );
    CREATE TABLE parts (
      automation_id INTEGER NOT NULL,
      key TEXT NOT NULL,
      added_at INTEGER NOT NULL,
      last_run_at INTEGER,
      succeeded_at INTEGER,
      pending_drops TEXT NOT NULL,
      last_output TEXT NOT NULL,
      breach TEXT,
      PRIMARY KEY (automation_id, key)
    );
    CREATE TABLE inbox (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      automation_id INTEGER NOT NULL,
      part_key TEXT NOT NULL,
      item_id TEXT NOT NULL,
      arrived_at INTEGER NOT NULL,
      size INTEGER NOT NULL,
      origin_part TEXT,
      origin_item TEXT,
      origin_link TEXT,
      row TEXT NOT NULL,
      origin_body TEXT,
      UNIQUE (automation_id, part_key, item_id)
    );
    CREATE INDEX inbox_order ON inbox (automation_id, part_key, seq);
    CREATE TABLE proposals (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      link TEXT NOT NULL UNIQUE,
      state TEXT NOT NULL,
      task_id INTEGER,
      automation_id INTEGER NOT NULL,
      part_key TEXT NOT NULL,
      source_part_key TEXT NOT NULL,
      title TEXT NOT NULL,
      due TEXT,
      workspace TEXT,
      proposed_at INTEGER NOT NULL,
      item TEXT NOT NULL
    );
    CREATE TABLE runs (
      automation_id INTEGER NOT NULL,
      part_key TEXT NOT NULL,
      started_at INTEGER NOT NULL,
      record TEXT NOT NULL
    );
    CREATE INDEX runs_order ON runs (automation_id, part_key, started_at);
    """

  func transaction<T>(_ body: () throws -> T) throws -> T {
    try db.transaction(body)
  }

  /// この DB を `copy` へ写すバックアップ（`SQLiteBackup`）。
  func backup(into copy: SQLiteDatabase) throws -> SQLiteBackup {
    try SQLiteBackup(from: db, to: copy)
  }

  // MARK: - 自動化と部品の状態

  /// 足して ID を返す。
  func insert(_ automation: Automation) throws -> Int {
    try db.run(
      """
      INSERT INTO automations (definition, paused, created_at, accepted, dismissed)
      VALUES (?, ?, ?, ?, ?)
      """,
      [
        .text(try Self.encode(automation.definition)), .integer(automation.paused ? 1 : 0),
        .integer(AutomationPersistence.millis(automation.createdAt)),
        .integer(Int64(automation.tally.accepted)), .integer(Int64(automation.tally.dismissed)),
      ])
    return Int(db.lastInsertRowID)
  }

  func update(_ automation: Automation) throws {
    try db.run(
      "UPDATE automations SET definition = ?, paused = ?, accepted = ?, dismissed = ? WHERE id = ?",
      [
        .text(try Self.encode(automation.definition)), .integer(automation.paused ? 1 : 0),
        .integer(Int64(automation.tally.accepted)), .integer(Int64(automation.tally.dismissed)),
        .integer(Int64(automation.id)),
      ])
  }

  /// 自動化と、その部品の状態・溜まり・記録を消す。
  func delete(automation id: Int) throws {
    let owner: [SQLiteValue] = [.integer(Int64(id))]
    try db.run("DELETE FROM automations WHERE id = ?", owner)
    try db.run("DELETE FROM parts WHERE automation_id = ?", owner)
    try db.run("DELETE FROM inbox WHERE automation_id = ?", owner)
    try db.run("DELETE FROM runs WHERE automation_id = ?", owner)
  }

  /// 部品の状態の列を書く（記録と溜まりは別に書く）。
  func put(part key: String, of id: Int, _ state: AutomationPartState) throws {
    try db.run(
      """
      INSERT OR REPLACE INTO parts
        (automation_id, key, added_at, last_run_at, succeeded_at, pending_drops, last_output, breach)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .integer(Int64(id)), .text(key), .integer(AutomationPersistence.millis(state.addedAt)),
        Self.instant(state.lastRunAt), Self.instant(state.succeededAt),
        .text(try Self.encode(state.pendingDrops)), .text(try Self.encode(state.lastOutput)),
        try state.breach.map { .text(try Self.encode($0)) } ?? .null,
      ])
  }

  /// 部品の状態・溜まり・記録を消す。
  func delete(part key: String, of id: Int) throws {
    let owner: [SQLiteValue] = [.integer(Int64(id)), .text(key)]
    try db.run("DELETE FROM parts WHERE automation_id = ? AND key = ?", owner)
    try db.run("DELETE FROM inbox WHERE automation_id = ? AND part_key = ?", owner)
    try db.run("DELETE FROM runs WHERE automation_id = ? AND part_key = ?", owner)
  }

  /// 回の記録を足し、その部品の新しい `retainedRuns` 件だけを残す。
  func insert(run: AutomationPartRun, part key: String, of id: Int) throws {
    let owner: [SQLiteValue] = [.integer(Int64(id)), .text(key)]
    try db.run(
      "INSERT INTO runs (automation_id, part_key, started_at, record) VALUES (?, ?, ?, ?)",
      owner + [.integer(AutomationPersistence.millis(run.startedAt)), .text(try Self.encode(run))])
    try db.run(
      """
      DELETE FROM runs WHERE automation_id = ? AND part_key = ? AND rowid NOT IN (
        SELECT rowid FROM runs WHERE automation_id = ? AND part_key = ?
        ORDER BY started_at DESC, rowid DESC LIMIT ?)
      """, owner + owner + [.integer(Int64(AutomationPartState.retainedRuns))])
  }

  // MARK: - 溜まり

  /// 溜まりの目録（本文なし、通し番号の順）。
  func inbox(of key: String, in id: Int) throws -> [AutomationInbox.Row] {
    try db.select(
      """
      SELECT seq, item_id, origin_part, origin_item, origin_link, size, arrived_at FROM inbox
      WHERE automation_id = ? AND part_key = ? ORDER BY seq
      """, [.integer(Int64(id)), .text(key)]
    ) { s in
      var origin: AutomationInbox.Origin?
      if let part = s.text(at: 2), let item = s.text(at: 3), let link = s.text(at: 4) {
        origin = AutomationInbox.Origin(part: part, item: item, link: link)
      }
      return AutomationInbox.Row(
        seq: s.int(at: 0), id: s.text(at: 1) ?? "", origin: origin, size: s.int(at: 5),
        arrivedAt: AutomationPersistence.date(s.int64(at: 6)))
    }
  }

  /// 溜まりの件数と最も新しい通し番号。
  func inboxCount(of key: String, in id: Int) throws -> (count: Int, newest: Int) {
    let rows = try db.select(
      "SELECT count(*), coalesce(max(seq), 0) FROM inbox WHERE automation_id = ? AND part_key = ?",
      [.integer(Int64(id)), .text(key)]
    ) { ($0.int(at: 0), $0.int(at: 1)) }
    return rows.first ?? (0, 0)
  }

  /// 取った行の本文（`seqs` の順）。出どころの項目は行そのものか、行に添えた本文から組む。消えていた行は飛ばす。
  func rows(_ seqs: [Int]) throws -> [AutomationPartRow] {
    try seqs.compactMap { seq in
      try db.select(
        "SELECT item_id, row, origin_part, origin_item, origin_link, origin_body FROM inbox WHERE seq = ?",
        [.integer(Int64(seq))]
      ) { s -> AutomationPartRow? in
        guard let id = s.text(at: 0), let text = s.text(at: 1) else { return nil }
        guard let part = s.text(at: 2), let item = s.text(at: 3), let link = s.text(at: 4) else {
          return AutomationPartRow(id: id, text: text, origin: nil)
        }
        let body =
          s.text(at: 5).flatMap { Self.decode(OriginBody.self, $0) }
          ?? Self.decode(AutomationItem.self, text).map { OriginBody(body: $0.body, time: $0.time) }
        guard let body else { return nil }
        return AutomationPartRow(
          id: id, text: text,
          origin: AutomationOrigin(
            part: part, item: AutomationItem(id: item, link: link, body: body.body, time: body.time)
          ))
      }.first ?? nil
    }
  }

  func delete(inbox seqs: [Int]) throws {
    for seq in seqs { try db.run("DELETE FROM inbox WHERE seq = ?", [.integer(Int64(seq))]) }
  }

  /// 行を積む。行そのものが出どころの項目（取得が出した行。出どころの部品が入力の部品と同じ）なら、本文を二重に持たない。
  func stack(
    _ row: AutomationPartRow, into key: String, of id: Int, from input: String, at arrivedAt: Date
  ) throws {
    let origin = row.origin
    let originIsRow = origin?.part == input
    try db.run(
      """
      INSERT INTO inbox (automation_id, part_key, item_id, arrived_at, size, origin_part, origin_item,
        origin_link, row, origin_body)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .integer(Int64(id)), .text(key), .text(row.id),
        .integer(AutomationPersistence.millis(arrivedAt)), .integer(Int64(row.text.utf8.count)),
        origin.map { .text($0.part) } ?? .null, origin.map { .text($0.item.id) } ?? .null,
        origin.map { .text($0.item.link) } ?? .null, .text(row.text),
        try origin.flatMap { originIsRow ? nil : $0 }.map {
          .text(try Self.encode(OriginBody(body: $0.item.body, time: $0.item.time)))
        } ?? .null,
      ])
  }

  /// 行に添える出どころの項目の本文と時刻。
  private struct OriginBody: Codable {
    let body: String
    let time: Date
  }

  // MARK: - 候補

  /// 足して ID を返す。
  func insert(proposal: AutomationProposal) throws -> Int {
    try db.run(
      """
      INSERT INTO proposals (link, state, task_id, automation_id, part_key, source_part_key, title, due,
        workspace, proposed_at, item)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .text(proposal.item.link), .text(proposal.state.name), Self.taskId(proposal.state),
        .integer(Int64(proposal.automationId)), .text(proposal.partKey),
        .text(proposal.sourcePartKey), .text(proposal.title),
        proposal.due.map { .text($0.text) } ?? .null,
        proposal.workspace.map { .text($0.uuidString) } ?? .null,
        .integer(AutomationPersistence.millis(proposal.proposedAt)),
        .text(try Self.encode(proposal.item)),
      ])
    return Int(db.lastInsertRowID)
  }

  func update(proposal: AutomationProposal) throws {
    try db.run(
      "UPDATE proposals SET state = ?, task_id = ? WHERE id = ?",
      [.text(proposal.state.name), Self.taskId(proposal.state), .integer(Int64(proposal.id))])
  }

  func delete(proposals ids: [Int]) throws {
    for id in ids { try db.run("DELETE FROM proposals WHERE id = ?", [.integer(Int64(id))]) }
  }

  // MARK: - 値

  private static func taskId(_ state: AutomationProposal.State) -> SQLiteValue {
    if case .accepted(let taskId) = state { .integer(Int64(taskId)) } else { .null }
  }

  private static func instant(_ date: Date?) -> SQLiteValue {
    date.map { .integer(AutomationPersistence.millis($0)) } ?? .null
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
