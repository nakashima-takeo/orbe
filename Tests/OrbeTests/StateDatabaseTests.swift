import OrbeTestSupport
import XCTest

@testable import Orbe

/// state の DB を開くとき、使えない DB はフォルダごと退避して空で始め、退避できない・確かめられない DB は動かさずに
/// 接続を返さないこと。
///
/// 壊れると何が起きるか: 健全な DB を開き直すたびに失う。壊れた DB や版の違う DB で起動できなくなるか、退避せずに
/// 上書きして人が積み上げた中身を復元できなくなる。退避できなかった原本に書き、守るはずの中身を潰す。一時的に
/// 確かめられなかっただけの健全な DB を退避し、次の退避で消す。退避物の掃除が、同じ名前の JSON の退避物を消す。
final class StateDatabaseTests: OrbeTestCase {
  private static let schemaV1 = "CREATE TABLE item (name TEXT NOT NULL)"
  /// 版 2 は表の形を変えた、という想定（版 1 の表は作らない）。
  private static let schemaV2 = "CREATE TABLE entry (title TEXT NOT NULL)"

  private var folder: URL { TestScratch.caseDir.appendingPathComponent("automations") }

  private func quarantinedFolders() throws -> [URL] {
    let dir = folder.deletingLastPathComponent()
    return try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter {
        $0.range(of: #"^automations-broken-\d{8}-\d{6}$"#, options: .regularExpression) != nil
      }
      .sorted().map { dir.appendingPathComponent($0) }
  }

  /// 版 1 の DB を作り、行を書いて閉じる。
  private func seedVersion1(_ names: [String], in folder: URL? = nil) throws {
    let db = try XCTUnwrap(
      StateDatabase.open(folder: folder ?? self.folder, version: 1, schema: Self.schemaV1) { _ in ()
      }?.database)
    try db.transaction {
      for name in names {
        let insert = try db.prepare("INSERT INTO item VALUES (?)")
        try insert.bind([.text(name)])
        _ = try insert.step()
      }
    }
  }

  private func names(_ db: SQLiteDatabase) throws -> [String] {
    let select = try db.prepare("SELECT name FROM item ORDER BY rowid")
    var names: [String] = []
    while try select.step() { names.append(select.text(at: 0) ?? "") }
    return names
  }

  private func names(inVersion1At folder: URL) throws -> [String] {
    try names(
      XCTUnwrap(
        StateDatabase.open(folder: folder, version: 1, schema: Self.schemaV1) { _ in () }?.database)
    )
  }

  /// DB のフォルダの中の、SQLite の付属ファイル（-wal・-shm）でない本体。閉じた後は中身が本体へ書き戻されている。
  private func databaseFile(in folder: URL) throws -> URL {
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
      .filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
    XCTAssertEqual(names.count, 1, "DB の本体は 1 つ: \(names)")
    return folder.appendingPathComponent(try XCTUnwrap(names.first))
  }

  private func tableCount(_ db: SQLiteDatabase, named name: String) throws -> Int64 {
    let statement = try db.prepare("SELECT count(*) FROM sqlite_master WHERE name = ?")
    try statement.bind([.text(name)])
    XCTAssertTrue(try statement.step())
    return statement.int64(at: 0)
  }

  /// 退避の後に返った接続が、新しい版の空の DB であること。
  private func assertStartsEmpty(
    _ db: SQLiteDatabase?, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let db = try XCTUnwrap(db, "使えない DB は退避して空で始める", file: file, line: line)
    XCTAssertEqual(try tableCount(db, named: "entry"), 1, "新しい版の表がある", file: file, line: line)
    XCTAssertEqual(try tableCount(db, named: "item"), 0, "元の中身は持ち込まない", file: file, line: line)
  }

  /// ディレクトリへの新しいエントリ作成を禁じる。root で走るなど権限が効かない環境では skip する。
  private func denyEntryCreation(in dir: URL) throws {
    let fm = FileManager.default
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    let probe = dir.appendingPathComponent("probe")
    if (try? Data().write(to: probe)) != nil {
      try? fm.removeItem(at: probe)
      throw XCTSkip("ディレクトリ権限が効かない環境（root 等）では退避の失敗を作れない")
    }
  }

  func testWrittenRowsSurviveReopening() throws {
    try seedVersion1(["朝の報告", "夜の報告"])

    XCTAssertEqual(try names(inVersion1At: folder), ["朝の報告", "夜の報告"])
    XCTAssertEqual(try quarantinedFolders(), [], "版の合う DB は退避しない")
  }

  func testNonDatabaseIsQuarantinedWithItsBytesAndStartsEmpty() throws {
    try seedVersion1(["kept"])
    let garbage = Data("これは SQLite の DB ではない".utf8)
    try garbage.write(to: databaseFile(in: folder))

    let db = StateDatabase.open(folder: folder, version: 2, schema: Self.schemaV2) { _ in () }?
      .database

    try assertStartsEmpty(db)
    let quarantined = try quarantinedFolders()
    XCTAssertEqual(quarantined.count, 1, "フォルダごと退避される")
    XCTAssertEqual(
      try Data(contentsOf: databaseFile(in: XCTUnwrap(quarantined.first))), garbage,
      "DB でないバイト列は元のまま残る")
  }

  /// 見出しは読めても中が壊れた DB は、開くときの検査で見つけて退避する。
  func testDatabaseCorruptedInsideIsQuarantined() throws {
    try seedVersion1((0..<200).map { "行 \($0) " + String(repeating: "x", count: 100) })
    let file = try databaseFile(in: folder)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seek(toOffset: 4096)
    try handle.write(contentsOf: Data(repeating: 0xFF, count: 4096))
    try handle.close()

    let db = StateDatabase.open(folder: folder, version: 1, schema: Self.schemaV1) { _ in () }?
      .database

    XCTAssertEqual(try quarantinedFolders().count, 1, "中の壊れも退避する")
    XCTAssertEqual(try names(XCTUnwrap(db)), [], "空で始まる")
  }

  func testVersionMismatchIsQuarantinedWithReadableContent() throws {
    try seedVersion1(["版 1 の中身"])

    let db = StateDatabase.open(folder: folder, version: 2, schema: Self.schemaV2) { _ in () }?
      .database

    try assertStartsEmpty(db)
    let quarantined = try XCTUnwrap(quarantinedFolders().first)
    XCTAssertEqual(try names(inVersion1At: quarantined), ["版 1 の中身"], "退避物を開くと元の中身が読める")
  }

  /// 古い退避物のフォルダは消え、同じ名前の JSON の退避物は残る。
  func testQuarantineKeepsOnlyTheNewestFolderAndLeavesTheJSONQuarantine() throws {
    let dir = folder.deletingLastPathComponent()
    let staleFolder = dir.appendingPathComponent("automations-broken-19700101-000000")
    let jsonQuarantine = dir.appendingPathComponent("automations-broken-19700101-000000.json")
    try FileManager.default.createDirectory(at: staleFolder, withIntermediateDirectories: true)
    try Data("旧 JSON の退避物".utf8).write(to: jsonQuarantine)
    try seedVersion1(["版 1 の中身"])

    _ = StateDatabase.open(folder: folder, version: 2, schema: Self.schemaV2) { _ in () }?.database

    let quarantined = try quarantinedFolders()
    XCTAssertEqual(quarantined.count, 1, "退避物のフォルダは最新 1 件だけ")
    XCTAssertEqual(
      try names(inVersion1At: XCTUnwrap(quarantined.first)), ["版 1 の中身"], "残るのは今回の原本")
    XCTAssertEqual(
      try Data(contentsOf: jsonQuarantine), Data("旧 JSON の退避物".utf8),
      "拡張子の違う同じ名前の退避物は消さない")
  }

  /// 退避できなければ接続を返さず原本はそのまま残り、次に開いたときに退避をやり直す。
  func testConnectionIsWithheldWhileQuarantineFailsAndQuarantineIsRetriedOnNextOpen() throws {
    let parent = TestScratch.caseDir.appendingPathComponent("state")
    let folder = parent.appendingPathComponent("automations")
    try seedVersion1(["版 1 の中身"], in: folder)

    try denyEntryCreation(in: parent)
    XCTAssertNil(
      StateDatabase.open(folder: folder, version: 2, schema: Self.schemaV2) { _ in () }?.database,
      "退避できなければ接続を返さない（原本に新しい版を作らない）")

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
    let db = StateDatabase.open(folder: folder, version: 2, schema: Self.schemaV2) { _ in () }?
      .database

    try assertStartsEmpty(db)
    let quarantined = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(atPath: parent.path)
        .first { $0.hasPrefix("automations-broken-") })
    XCTAssertEqual(
      try names(inVersion1At: parent.appendingPathComponent(quarantined)), ["版 1 の中身"],
      "失敗の間も原本は元のまま残り、やり直した退避で守られる")
  }

  /// 読み取り専用の DB は動かさず、接続も返さない。
  func testReadOnlyDatabaseIsNeitherMovedNorOpened() throws {
    try seedVersion1(["版 1 の中身"])
    let file = try databaseFile(in: folder)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)

    XCTAssertNil(
      StateDatabase.open(folder: folder, version: 1, schema: Self.schemaV1) { _ in () }?.database)

    XCTAssertEqual(try quarantinedFolders(), [], "健全かもしれない原本を退避しない")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    XCTAssertEqual(try names(inVersion1At: folder), ["版 1 の中身"], "原本は元の場所に元のまま残る")
  }

  /// 開けずに使えると確かめられない DB は、健全かもしれないので退避せず、接続も返さない。
  func testUnopenableDatabaseIsNeitherQuarantinedNorOpened() throws {
    try seedVersion1(["版 1 の中身"])
    let file = try databaseFile(in: folder)
    let fm = FileManager.default
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    if (try? FileHandle(forReadingFrom: file)) != nil {
      try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
      throw XCTSkip("ファイル権限が効かない環境（root 等）では開けない DB を作れない")
    }

    XCTAssertNil(
      StateDatabase.open(folder: folder, version: 1, schema: Self.schemaV1) { _ in () }?.database)

    XCTAssertEqual(try quarantinedFolders(), [], "確かめられなかっただけの原本を退避しない")
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    XCTAssertEqual(try names(inVersion1At: folder), ["版 1 の中身"], "原本は元の場所に元のまま残る")
  }
}
