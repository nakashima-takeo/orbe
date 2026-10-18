import Foundation
import SQLite3

/// state の DB の開き方。DB は専用のフォルダに入れ、SQLite が作る付属ファイルごとフォルダを 1 つの原本として扱う。
/// 使えない DB はフォルダごと退避して空で作り直し、退避できなければ接続を返さない（＝そのセッションは書かない）。
///
/// 開いた接続は DB を排他で持ち続ける——同じ state を使う 2 つ目の Orbe は、開く時点の検査で読みも拒まれ、そのセッションは
/// その DB を読まず書かない。待たない（2 つの Orbe が同じ DB の予定を両方とも回し、副作用を二重に起こさないため）。
enum StateDatabase {
  private static let fileName = "db.sqlite"

  /// 開いた接続と、呼び手が開いた直後に読んだ中身。
  struct Opened<Contents> {
    let database: SQLiteDatabase
    let contents: Contents
  }

  /// folder の中の DB への使える接続と、`read` で読んだ中身を返す。使えない DB（`read` が nil を返した＝呼び手の読みとして
  /// 使えない、を含む）はフォルダごと退避して、空で作り直す。返せないとき（退避できなかった・使えると確かめられない・別の接続が
  /// 持っている）は nil で、そのセッションはその DB に書かない。`read` が投げたら確かめられないとみなす（DB の壊れを除く）。
  static func open<Contents>(
    folder: URL, version: Int32, schema: String, read: (SQLiteDatabase) throws -> Contents?
  ) -> Opened<Contents>? {
    precondition(version >= 1, "版 0 は空の DB と区別できない")
    let url = folder.appendingPathComponent(fileName)
    guard makeFolder(folder) else { return nil }
    func fresh() -> Opened<Contents>? {
      Self.fresh(url, version: version, schema: schema, read)
    }
    func recreate(_ reason: String) -> Opened<Contents>? {
      NSLog("[state] unusable database \(url.path): \(reason)")
      var quarantine = StateFileQuarantine()
      quarantine.quarantine(folder)
      guard quarantine.permitsWrite(to: folder), makeFolder(folder) else { return nil }
      return fresh()
    }
    switch inspect(url, version: version) {
    case .usable:
      switch load(url, read) {
      case .loaded(let opened): return opened
      case .unreadable(let reason): return recreate(reason)
      case .failed: return nil
      }
    case .empty:
      return fresh()
    case .unusable(let reason):
      return recreate(reason)
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
    /// 使えるかを確かめられなかった（I/O・権限・別の接続が持っているなど）。
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
    } catch let error as SQLiteError where error.isBroken {
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

  private enum Load<Contents> {
    case loaded(Opened<Contents>)
    /// 呼び手の読みとして使えない（読めない行・壊れ）。戻った時点で接続は解放されている。
    case unreadable(String)
    case failed
  }

  private static func load<Contents>(
    _ url: URL, _ read: (SQLiteDatabase) throws -> Contents?
  ) -> Load<Contents> {
    guard let db = connect(url) else { return .failed }
    do {
      guard let contents = try read(db) else { return .unreadable("unreadable rows") }
      return .loaded(Opened(database: db, contents: contents))
    } catch let error as SQLiteError where error.isBroken {
      return .unreadable("\(error)")
    } catch {
      NSLog("[state] cannot read database, save disabled: \(url.path): \(error)")
      return .failed
    }
  }

  /// 作り直した空の DB を読む。空でも読めなければ返さない。
  private static func fresh<Contents>(
    _ url: URL, version: Int32, schema: String, _ read: (SQLiteDatabase) throws -> Contents?
  ) -> Opened<Contents>? {
    guard let db = create(url, version: version, schema: schema) else { return nil }
    do {
      guard let contents = try read(db) else {
        NSLog("[state] cannot read a new database, save disabled: \(url.path)")
        return nil
      }
      return Opened(database: db, contents: contents)
    } catch {
      NSLog("[state] cannot read a new database, save disabled: \(url.path): \(error)")
      return nil
    }
  }

  /// 書き込み方式は使える・空と決まった後に設定する（退避する原本の見出しを書き換えない）。排他の鍵の持ち方は WAL より先に
  /// 決める（WAL の目録を共有メモリでなくこの接続の中に置く）。開いた直後に書き込みの鍵を取り、以後手放さない。取れなければ
  /// 別の接続が持っているので返さない。
  private static func connect(_ url: URL) -> SQLiteDatabase? {
    do {
      let db = try SQLiteDatabase(url: url)
      guard !db.isReadOnly else {
        NSLog("[state] database is read-only, save disabled: \(url.path)")
        return nil
      }
      try db.exec(
        """
        PRAGMA locking_mode = EXCLUSIVE; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;
        BEGIN EXCLUSIVE; COMMIT
        """)
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
