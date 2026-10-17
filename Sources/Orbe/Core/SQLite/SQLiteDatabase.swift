import Foundation
import SQLite3

/// SQLite が返した失敗。
struct SQLiteError: Error, CustomStringConvertible {
  /// 拡張結果コード。
  let code: Int32
  let message: String

  /// 主結果コード（拡張結果コードの下位 8 ビット）。
  var primaryCode: Int32 { code & 0xFF }

  var description: String { "SQLite \(code): \(message)" }
}

/// 束縛する値。
enum SQLiteValue: Equatable {
  case integer(Int64)
  case real(Double)
  case text(String)
  case null
}

/// SQLite の接続。解放で閉じる。main からだけ使う。
final class SQLiteDatabase {
  fileprivate let handle: OpaquePointer

  /// 読み書きで開き、無ければ作る。読み取りしか許されないファイルは黙って読み取り専用で開くので、`isReadOnly` で見る。
  init(url: URL) throws {
    var db: OpaquePointer?
    let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    guard rc == SQLITE_OK, let db else {
      let message =
        db.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(rc))
      sqlite3_close(db)
      throw SQLiteError(code: rc, message: message)
    }
    sqlite3_extended_result_codes(db, 1)
    handle = db
  }

  deinit {
    sqlite3_close(handle)
  }

  var isReadOnly: Bool { sqlite3_db_readonly(handle, "main") == 1 }

  /// 行を返さない文（複数可）を流す。
  func exec(_ sql: String) throws {
    let rc = sqlite3_exec(handle, sql, nil, nil, nil)
    guard rc == SQLITE_OK else { throw failure(rc) }
  }

  func prepare(_ sql: String) throws -> SQLiteStatement {
    var statement: OpaquePointer?
    let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard rc == SQLITE_OK else {
      sqlite3_finalize(statement)
      throw failure(rc)
    }
    guard let statement else {
      throw SQLiteError(code: SQLITE_MISUSE, message: "no statement in: \(sql)")
    }
    return SQLiteStatement(database: self, handle: statement)
  }

  /// `BEGIN IMMEDIATE` で始め、`body` が戻れば確定する。`body` が投げるか確定に失敗すれば巻き戻して投げる
  /// （SQLite が自分で巻き戻した後は自動確定に戻っているので、何もせず投げる）。入れ子にはできない。
  func transaction<T>(_ body: () throws -> T) throws -> T {
    try exec("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try exec("COMMIT")
      return result
    } catch {
      if sqlite3_get_autocommit(handle) == 0 { try? exec("ROLLBACK") }
      throw error
    }
  }

  fileprivate func failure(_ rc: Int32) -> SQLiteError {
    SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
  }
}

/// 準備済みの文。接続を強参照で持つので、文より先に接続が閉じることはない。解放で finalize する。
final class SQLiteStatement {
  private let database: SQLiteDatabase
  private let handle: OpaquePointer

  fileprivate init(database: SQLiteDatabase, handle: OpaquePointer) {
    self.database = database
    self.handle = handle
  }

  deinit {
    sqlite3_finalize(handle)
  }

  /// `values` を 1 番目の引数から順に束縛する。
  func bind(_ values: [SQLiteValue]) throws {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let rc: Int32
      switch value {
      case .integer(let int): rc = sqlite3_bind_int64(handle, index, int)
      case .real(let double): rc = sqlite3_bind_double(handle, index, double)
      case .text(let text):
        let length = Int32(text.utf8.count)
        rc = text.withCString { sqlite3_bind_text(handle, index, $0, length, sqliteTransient) }
      case .null: rc = sqlite3_bind_null(handle, index)
      }
      guard rc == SQLITE_OK else { throw database.failure(rc) }
    }
  }

  /// 行があれば true、終わりなら false。
  func step() throws -> Bool {
    switch sqlite3_step(handle) {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    case let rc: throw database.failure(rc)
    }
  }

  func int64(at column: Int) -> Int64 {
    sqlite3_column_int64(handle, Int32(column))
  }

  func double(at column: Int) -> Double {
    sqlite3_column_double(handle, Int32(column))
  }

  func text(at column: Int) -> String? {
    guard let bytes = sqlite3_column_text(handle, Int32(column)) else { return nil }
    let count = Int(sqlite3_column_bytes(handle, Int32(column)))
    return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
  }

  func isNull(at column: Int) -> Bool {
    sqlite3_column_type(handle, Int32(column)) == SQLITE_NULL
  }

  /// 最初から流し直せるように戻し、束縛も消す。
  func reset() {
    sqlite3_reset(handle)
    sqlite3_clear_bindings(handle)
  }
}

/// `SQLITE_TRANSIENT`（C のマクロなので Swift から見えない）。束縛した文字列を SQLite に複写させる。
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
