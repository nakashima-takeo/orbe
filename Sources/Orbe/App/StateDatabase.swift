import Foundation
import SQLite3

/// state の DB の開き方。DB は専用のフォルダに入れ、SQLite が作る付属ファイルごとフォルダを 1 つの原本として扱う。
/// 使えない DB はフォルダごと退避して空で作り直し、退避できなければ接続を返さない（＝そのセッションは書かない）。
enum StateDatabase {
  private static let fileName = "db.sqlite"

  /// folder の中の DB への使える接続を返す。使えない DB はフォルダごと退避して、空で作り直す。返せないとき
  /// （退避できなかった・使えると確かめられない）は nil で、そのセッションはその DB に書かない。
  /// 返った接続でも書けることは約束しない（別の接続が書き込みを握っていれば、トランザクションが失敗する）。
  static func open(folder: URL, version: Int32, schema: String) -> SQLiteDatabase? {
    precondition(version >= 1, "版 0 は空の DB と区別できない")
    let url = folder.appendingPathComponent(fileName)
    guard makeFolder(folder) else { return nil }
    switch inspect(url, version: version) {
    case .usable:
      return connect(url)
    case .empty:
      return create(url, version: version, schema: schema)
    case .unusable(let reason):
      NSLog("[state] unusable database \(url.path): \(reason)")
      var quarantine = StateFileQuarantine()
      quarantine.quarantine(folder)
      guard quarantine.permitsWrite(to: folder), makeFolder(folder) else { return nil }
      return create(url, version: version, schema: schema)
    case .unverifiable(let error):
      NSLog("[state] cannot verify database, save disabled: \(url.path): \(error)")
      return nil
    }
  }

  private enum Inspection {
    case usable
    /// 版 0 で表が 1 つも無い（DB が無い・0 バイトを含む）。
    case empty
    /// DB でない・壊れている・版が違う・Orbe が作ったのではない。
    case unusable(String)
    /// 使えるかを確かめられなかった（I/O・権限など）。
    case unverifiable(Error)
  }

  /// 戻った時点で検査の接続は解放されている（開いたまま退避すると、閉じるときの書き戻しが退避物を書き換える）。
  private static func inspect(_ url: URL, version: Int32) -> Inspection {
    do {
      let db = try SQLiteDatabase(url: url)
      let found = try firstColumn(db, "PRAGMA user_version") { $0.int64(at: 0) } ?? 0
      let check = try firstColumn(db, "PRAGMA quick_check") { $0.text(at: 0) }
      guard check == "ok" else { return .unusable("quick_check: \(check ?? "no result")") }
      if found == Int64(version) { return .usable }
      guard found == 0 else { return .unusable("version \(found), expected \(version)") }
      let tables =
        try firstColumn(db, "SELECT count(*) FROM sqlite_master") { $0.int64(at: 0) } ?? 0
      return tables == 0 ? .empty : .unusable("version 0 with existing schema")
    } catch let error as SQLiteError
      where error.primaryCode == SQLITE_NOTADB || error.primaryCode == SQLITE_CORRUPT
    {
      return .unusable("\(error)")
    } catch {
      return .unverifiable(error)
    }
  }

  private static func firstColumn<T>(
    _ db: SQLiteDatabase, _ sql: String, _ read: (SQLiteStatement) -> T?
  ) throws -> T? {
    let statement = try db.prepare(sql)
    return try statement.step() ? read(statement) : nil
  }

  /// 書き込み方式は使える・空と決まった後に設定する（退避する原本の見出しを書き換えない）。
  private static func connect(_ url: URL) -> SQLiteDatabase? {
    do {
      let db = try SQLiteDatabase(url: url)
      guard !db.isReadOnly else {
        NSLog("[state] database is read-only, save disabled: \(url.path)")
        return nil
      }
      try db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL")
      return db
    } catch {
      NSLog("[state] cannot open database, save disabled: \(url.path): \(error)")
      return nil
    }
  }

  /// 表作りと版の刻みを 1 トランザクションにする（表だけ出来て版が 0 のまま、を残さない）。
  private static func create(_ url: URL, version: Int32, schema: String) -> SQLiteDatabase? {
    guard let db = connect(url) else { return nil }
    do {
      try db.transaction {
        try db.exec(schema)
        try db.exec("PRAGMA user_version = \(version)")
      }
      return db
    } catch {
      NSLog("[state] cannot create database, save disabled: \(url.path): \(error)")
      return nil
    }
  }

  private static func makeFolder(_ folder: URL) -> Bool {
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      return true
    } catch {
      NSLog("[state] cannot create database folder, save disabled: \(folder.path): \(error)")
      return false
    }
  }
}
