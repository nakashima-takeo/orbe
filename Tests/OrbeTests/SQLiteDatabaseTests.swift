import OrbeTestSupport
import XCTest

@testable import Orbe

/// SQLite の包みが、束縛した値をそのまま読み返させ、失敗したトランザクションを何も残さず終えること。
///
/// 壊れると何が起きるか: 文字列の束縛の長さや寿命を取り違えると、日本語を含む保存の中身が黙って欠けたり化けたりする。
/// 失敗したトランザクションを巻き戻さないと、途中まで書いた行が残り、「DB が通ってからメモリ」に乗る呼び手の
/// メモリと DB がずれる。
final class SQLiteDatabaseTests: OrbeTestCase {
  private func openDatabase() throws -> SQLiteDatabase {
    try SQLiteDatabase(url: TestScratch.caseDir.appendingPathComponent("test.sqlite"))
  }

  private func count(_ db: SQLiteDatabase, _ table: String) throws -> Int64 {
    let statement = try db.prepare("SELECT count(*) FROM \(table)")
    XCTAssertTrue(try statement.step())
    return statement.int64(at: 0)
  }

  func testBoundValuesReadBackUnchanged() throws {
    let db = try openDatabase()
    try db.exec("CREATE TABLE value (i INTEGER, r REAL, t TEXT, n TEXT)")
    let text = "日本語と絵文字🙂を含む {\"json\": \"本文\"}"

    let insert = try db.prepare("INSERT INTO value VALUES (?, ?, ?, ?)")
    try insert.bind([.integer(Int64.max), .real(-1.25), .text(text), .null])
    XCTAssertFalse(try insert.step())

    let select = try db.prepare("SELECT i, r, t, n FROM value")
    XCTAssertTrue(try select.step())
    XCTAssertEqual(select.int64(at: 0), Int64.max)
    XCTAssertEqual(select.double(at: 1), -1.25)
    XCTAssertEqual(select.text(at: 2), text, "多バイトの文字列が欠けず化けずに戻る")
    XCTAssertTrue(select.isNull(at: 3))
    XCTAssertFalse(try select.step(), "行は 1 つだけ")
  }

  /// 本体の途中の文が失敗すると、それより前に書いた行も残らない。
  func testFailingTransactionLeavesNothingWritten() throws {
    let db = try openDatabase()
    try db.exec("CREATE TABLE item (name TEXT UNIQUE)")

    XCTAssertThrowsError(
      try db.transaction {
        for name in ["a", "b", "a"] {
          let insert = try db.prepare("INSERT INTO item VALUES (?)")
          try insert.bind([.text(name)])
          _ = try insert.step()
        }
      })

    XCTAssertEqual(try count(db, "item"), 0, "失敗より前の行も巻き戻る")
  }
}
