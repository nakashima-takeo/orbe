import Foundation
import SQLite3

/// state の DB の開き方。DB は専用のフォルダに入れ、SQLite が作る付属ファイルごとフォルダを 1 つの原本として扱う。
///
/// 版（`user_version`）ごとに扱いを決める。今の版はそのまま、古い版は移行の列を順にたどって今の版へ移し（たどれなければ退避）、
/// 新しい版は動かさずに使わない。開くときは表と索引の定義を、今の版の表作りの文から作った空の DB と照らし、合わなければ
/// 退避する。退避はフォルダごと動かして空で作り直し、退避できなければ使わない。使わないときは理由を返し、そのセッションは
/// その DB を読まず書かない。
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

  /// 開いた結果。使わないときは、外の口で言える理由（「the database」に続く英文）を持つ。
  enum Opening<Contents> {
    case opened(Opened<Contents>)
    case refused(String)

    var opened: Opened<Contents>? {
      if case .opened(let opened) = self { opened } else { nil }
    }
  }

  /// 版 `from` の DB を版 `from + 1` へ移す。開いた接続の 1 トランザクションの中で呼ぶ。
  struct Migration {
    let from: Int32
    let run: (SQLiteDatabase) throws -> Void
  }

  /// folder の中の DB を開き、`read` で読んだ中身と返す。`read` が投げたら、DB の壊れなら退避し、それ以外は使わない。
  static func open<Contents>(
    folder: URL, version: Int32, schema: String, migrations: [Migration] = [],
    read: (SQLiteDatabase) throws -> Contents
  ) -> Opening<Contents> {
    precondition(version >= 1, "版 0 は空の DB と区別できない")
    let url = folder.appendingPathComponent(fileName)
    guard makeFolder(folder) else { return .refused("folder cannot be created") }
    let expected: [String]
    do {
      expected = try shape(ofSchema: schema)
    } catch {
      return refuse(url, "schema cannot be built: \(error)")
    }
    func recreate(_ reason: String) -> Opening<Contents> {
      NSLog("[state] unusable database \(url.path): \(reason)")
      var quarantine = StateFileQuarantine()
      quarantine.quarantine(folder)
      guard quarantine.permitsWrite(to: folder), makeFolder(folder) else {
        return .refused("is unusable and could not be set aside")
      }
      return fresh(url, version: version, schema: schema, read)
    }
    switch inspect(url) {
    case .empty:
      return fresh(url, version: version, schema: schema, read)
    case .unusable(let reason):
      return recreate(reason)
    case .unverifiable(let error):
      return refuse(url, "cannot be checked: \(error)")
    case .version(let found, let shape):
      if found > Int64(version) {
        return refuse(
          url,
          "is version \(found), newer than this Orbe understands (\(version)), and is "
            + "left untouched")
      }
      if found == Int64(version) {
        guard shape == expected else { return recreate("its tables differ from version \(found)") }
        return load(url, read, recreate: recreate)
      }
      let chain = (Int32(found)..<version).map { from in migrations.first { $0.from == from } }
      guard chain.allSatisfy({ $0 != nil }) else {
        return recreate("version \(found) has no migration to version \(version)")
      }
      switch migrate(url, from: found, to: version, chain.compactMap { $0 }, expected: expected) {
      case .migrated: return load(url, read, recreate: recreate)
      case .differs:
        return recreate("its tables after the migration differ from version \(version)")
      case .refused(let reason): return refuse(url, reason)
      }
    }
  }

  private enum Inspection {
    /// 版 0 で表が 1 つも無い（DB が無い・0 バイトを含む）。
    case empty
    /// 版と、表と索引の定義。
    case version(Int64, shape: [String])
    /// DB でない・壊れている・Orbe が作ったのではない。
    case unusable(String)
    /// 使えるかを確かめられなかった（I/O・権限・別の接続が持っているなど）。
    case unverifiable(Error)
  }

  /// 戻った時点で検査の接続は解放されている（開いたまま退避すると、閉じるときの書き戻しが退避物を書き換える）。
  private static func inspect(_ url: URL) -> Inspection {
    do {
      let db = try SQLiteDatabase(url: url)
      let found = try firstColumn(db, "PRAGMA user_version") { $0.int64(at: 0) } ?? 0
      let check = try firstColumn(db, "PRAGMA quick_check") { $0.text(at: 0) }
      guard check == "ok" else { return .unusable("quick_check: \(check ?? "no result")") }
      let shape = try self.shape(db)
      if found > 0 { return .version(found, shape: shape) }
      return shape.isEmpty ? .empty : .unusable("version 0 with existing schema")
    } catch let error as SQLiteError where error.isBroken {
      return .unusable("\(error)")
    } catch {
      return .unverifiable(error)
    }
  }

  /// 表と索引の定義（SQLite が自分で作るものを除く。空白の違いは見ない）。
  private static func shape(_ db: SQLiteDatabase) throws -> [String] {
    try db.select(
      """
      SELECT type, name, tbl_name, coalesce(sql, '') FROM sqlite_master
      WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name
      """, []
    ) { s in
      [0, 1, 2, 3].map { s.text(at: $0) ?? "" }.joined(separator: "\u{0}")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
  }

  private static func shape(ofSchema schema: String) throws -> [String] {
    let db = try SQLiteDatabase.memory()
    try db.exec(schema)
    return try shape(db)
  }

  private static func firstColumn<T>(
    _ db: SQLiteDatabase, _ sql: String, _ read: (SQLiteStatement) -> T?
  ) throws -> T? {
    let statement = try db.prepare(sql)
    return try statement.step() ? read(statement) : nil
  }

  private static func refuse<Contents>(_ url: URL, _ reason: String) -> Opening<Contents> {
    NSLog("[state] database not used, save disabled: \(url.path): \(reason)")
    return .refused(reason)
  }

  /// 開いて読む。読みが DB の壊れで投げたら、接続を解放してから退避する。
  private static func load<Contents>(
    _ url: URL, _ read: (SQLiteDatabase) throws -> Contents,
    recreate: (String) -> Opening<Contents>
  ) -> Opening<Contents> {
    let result: Result<Opened<Contents>, Error>
    do {
      let db = try connect(url)
      result = Result { Opened(database: db, contents: try read(db)) }
    } catch {
      return refuse(url, "cannot be opened (another Orbe may hold it): \(error)")
    }
    switch result {
    case .success(let opened): return .opened(opened)
    case .failure(let error as SQLiteError) where error.isBroken: return recreate("\(error)")
    case .failure(let error): return refuse(url, "cannot be read: \(error)")
    }
  }

  private enum Migrated {
    case migrated
    /// 移した後の表の形が今の版と違う。
    case differs
    case refused(String)
  }

  /// 移行の列を 1 トランザクションで流して版を刻み、表の形を照らす。移行が投げたら巻き戻し、原本を動かさずに使わない。戻った
  /// 時点で接続は解放されている。
  private static func migrate(
    _ url: URL, from found: Int64, to version: Int32, _ chain: [Migration], expected: [String]
  ) -> Migrated {
    do {
      let db = try connect(url)
      do {
        try db.transaction {
          for migration in chain { try migration.run(db) }
          try db.exec("PRAGMA user_version = \(version)")
        }
      } catch {
        return .refused("cannot be migrated from version \(found): \(error)")
      }
      return try shape(db) == expected ? .migrated : .differs
    } catch {
      return .refused("cannot be opened (another Orbe may hold it): \(error)")
    }
  }

  /// 作り直した空の DB を読む。空でも読めなければ使わない。
  private static func fresh<Contents>(
    _ url: URL, version: Int32, schema: String, _ read: (SQLiteDatabase) throws -> Contents
  ) -> Opening<Contents> {
    do {
      let db = try connect(url)
      try db.transaction {
        try db.exec(schema)
        try db.exec("PRAGMA user_version = \(version)")
      }
      return .opened(Opened(database: db, contents: try read(db)))
    } catch {
      return refuse(url, "cannot be made anew: \(error)")
    }
  }

  /// 書き込み方式は使える・空と決まった後に設定する（退避する原本の見出しを書き換えない）。排他の鍵の持ち方は WAL より先に
  /// 決める（WAL の目録を共有メモリでなくこの接続の中に置く）。開いた直後に書き込みの鍵を取り、以後手放さない。取れなければ
  /// 別の接続が持っている。外部キーはこの接続で守る。
  private static func connect(_ url: URL) throws -> SQLiteDatabase {
    let db = try SQLiteDatabase(url: url)
    guard !db.isReadOnly else {
      throw SQLiteError(code: SQLITE_READONLY, message: "the database is read-only")
    }
    try db.exec(
      """
      PRAGMA locking_mode = EXCLUSIVE; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;
      PRAGMA foreign_keys = ON; BEGIN EXCLUSIVE; COMMIT
      """)
    return db
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
