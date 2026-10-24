import OrbeTestSupport
import XCTest

@testable import Orbe

/// 形の照合の観点。
///
/// 壊れると何が起きるか: 観点ごとの問い合わせが黙って空振りし、作り直しの移行で外部キーや一意の制約を書き漏らした DB が
/// 照合を通ってコミットされる（書くときの整合の守りが外れる）。
extension StateDatabaseTests {
  /// 形は観点ごとに照らす: 表・列・索引の名前・外部キー・一意の制約・索引の一意・部分索引か・索引の列・WITHOUT ROWID・STRICT の
  /// どれか 1 つだけが違う同じ版の DB も退避する。
  func testEachAspectOfTheShapeIsCompared() throws {
    let base = """
      CREATE TABLE owner (id INTEGER PRIMARY KEY);
      CREATE TABLE item (id INTEGER PRIMARY KEY, owner_id INTEGER, name TEXT NOT NULL);
      CREATE INDEX item_name ON item (name);
      """
    let variants = [
      "table name": base.replacingOccurrences(of: "TABLE owner", with: "TABLE holder"),
      "column name": base.replacingOccurrences(of: "owner_id INTEGER", with: "holder_id INTEGER"),
      "index name": base.replacingOccurrences(of: "INDEX item_name", with: "INDEX item_label"),
      "foreign key": base.replacingOccurrences(
        of: "owner_id INTEGER,", with: "owner_id INTEGER REFERENCES owner (id),"),
      "unique": base.replacingOccurrences(
        of: "name TEXT NOT NULL)", with: "name TEXT NOT NULL UNIQUE)"),
      "unique index": base.replacingOccurrences(of: "CREATE INDEX", with: "CREATE UNIQUE INDEX"),
      "partial index": base.replacingOccurrences(of: "(name);", with: "(name) WHERE name <> '';"),
      "index columns": base.replacingOccurrences(of: "(name);", with: "(owner_id);"),
      "without rowid": base.replacingOccurrences(
        of: "name TEXT NOT NULL);", with: "name TEXT NOT NULL) WITHOUT ROWID;"),
      "strict": base.replacingOccurrences(
        of: "name TEXT NOT NULL);", with: "name TEXT NOT NULL) STRICT;"),
    ]
    func rows(in folder: URL, _ schema: String) throws -> Int64 {
      let db = try XCTUnwrap(
        StateDatabase.open(folder: folder, version: 1, schema: schema) { _ in () }.opened?.database)
      let count = try db.prepare("SELECT count(*) FROM item")
      XCTAssertTrue(try count.step())
      return count.int64(at: 0)
    }
    for (aspect, schema) in variants.sorted(by: { $0.key < $1.key }) {
      XCTAssertNotEqual(schema, base, "前提: \(aspect) だけを変えた")
      let folder = TestScratch.caseDir.appendingPathComponent(aspect).appendingPathComponent("db")
      try XCTUnwrap(
        StateDatabase.open(folder: folder, version: 1, schema: base) { _ in () }.opened?.database
      ).exec("INSERT INTO item VALUES (1, NULL, 'a')")
      XCTAssertEqual(try rows(in: folder, base), 1, "前提: 同じ形なら中身が残る")

      XCTAssertEqual(try rows(in: folder, schema), 0, "\(aspect) の違いで退避して空で始める")
    }
  }
}
