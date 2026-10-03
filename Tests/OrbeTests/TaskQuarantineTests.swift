import XCTest

@testable import Orbe

/// 使えなかった `tasks.json` の退避と、退避できなかったときの保存停止を固定する。
///
/// 壊れると何が起きるか: 原本を退避しないまま空の一覧で起動すると、次の変異の即時保存が原本を
/// 完全に潰す。人と agent が書き溜めたタスクを、気づく機会が一度も無いまま失う。退避の規律そのもの
/// （最新 1 件だけ残す・名前の形）は workspaces.json と共有の部品で、`WorkspaceQuarantineTests` が持つ。
/// ここは tasks.json がその規律に乗っていることと、tasks.json 固有の「使えない」の判定を見る。
final class TaskQuarantineTests: OrbeTestCase {
  private let corruptJSON = #"{"version":1,"nextId":3,"tasks":[{"id":1,"title":"経費"#

  private func quarantineFiles() throws -> [URL] {
    let dir = try tasksFile().deletingLastPathComponent()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasPrefix("tasks-broken-") && $0.hasSuffix(".json") }
      .sorted().map { dir.appendingPathComponent($0) }
  }

  private func taskJSON(id: Int) -> String {
    #"{"id":\#(id),"title":"t\#(id)","status":"todo","priority":"medium","memo":""#
      + #","createdAt":"2027-01-15T08:00:00.000Z"}"#
  }

  private func assertQuarantined(
    _ original: String, _ reason: String, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    try Data(original.utf8).write(to: tasksFile())

    XCTAssertNil(TaskPersistence.load(), "\(reason) は空の一覧で始める", file: file, line: line)

    let quarantined = try quarantineFiles()
    XCTAssertEqual(quarantined.count, 1, "\(reason) の原本は退避される", file: file, line: line)
    XCTAssertEqual(
      try Data(contentsOf: XCTUnwrap(quarantined.first)), Data(original.utf8),
      "退避物は原本とバイト単位で一致する", file: file, line: line)
    XCTAssertNotNil(
      quarantined.first?.lastPathComponent.range(
        of: #"^tasks-broken-\d{8}-\d{6}\.json$"#, options: .regularExpression),
      "退避物の名前は tasks-broken-<日時>.json", file: file, line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: try tasksFile().path), "原位置は空く", file: file,
      line: line)
  }

  func testCorruptFileIsQuarantinedWithOriginalBytes() throws {
    try assertQuarantined(corruptJSON, "構造破損")
  }

  func testIncompatibleVersionIsQuarantined() throws {
    try assertQuarantined(
      #"{"version":999,"nextId":2,"tasks":[\#(taskJSON(id: 1))]}"#, "非互換 version")
  }

  func testDuplicateIdsAreQuarantined() throws {
    try assertQuarantined(
      #"{"version":1,"nextId":3,"tasks":[\#(taskJSON(id: 1)),\#(taskJSON(id: 1))]}"#, "ID の重複")
  }

  /// 採番位置より大きい ID が残っていると、次の追加が既存の ID を振り直してしまう。
  func testIdAtOrBeyondTheNextIdIsQuarantined() throws {
    try assertQuarantined(
      #"{"version":1,"nextId":2,"tasks":[\#(taskJSON(id: 2))]}"#, "採番位置と矛盾する ID")
  }

  func testMissingFileStartsEmptyWithoutQuarantine() throws {
    XCTAssertNil(TaskPersistence.load())

    XCTAssertTrue(try quarantineFiles().isEmpty, "初回起動は退避物を作らない")
    let store = TaskStore()
    _ = try store.add(TaskDraft(title: "最初"))
    XCTAssertEqual(TaskStore().tasks.map(\.title), ["最初"], "初回起動の保存は通常どおりディスクへ届く")
  }

  func testStoreStartsEmptyFromACorruptFileAndSavesAfterQuarantine() throws {
    try Data(corruptJSON.utf8).write(to: tasksFile())

    let store = TaskStore()
    XCTAssertTrue(store.tasks.isEmpty, "壊れた tasks.json では空の一覧で起動する")
    _ = try store.add(TaskDraft(title: "新しい"))

    XCTAssertEqual(TaskStore().tasks.map(\.title), ["新しい"], "退避に成功したら以後の変異は保存される")
    XCTAssertEqual(
      try Data(contentsOf: XCTUnwrap(quarantineFiles().first)), Data(corruptJSON.utf8),
      "退避物は以後の保存で潰れない")
  }

  /// 退避に失敗した原本は、空の一覧で始めた後の変異で潰さない。
  func testSaveIsBlockedWhenQuarantineFails() throws {
    let url = try tasksFile()
    let dir = url.deletingLastPathComponent()
    try Data(corruptJSON.utf8).write(to: url)

    // 退避（＝ディレクトリへの新しいエントリ作成）だけを失敗させる。root では権限が効かないので skip する。
    let fm = FileManager.default
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
    let probe = dir.appendingPathComponent("probe")
    if (try? Data().write(to: probe)) != nil {
      try? fm.removeItem(at: probe)
      throw XCTSkip("ディレクトリ権限が効かない環境（root 等）では退避失敗を作れない")
    }

    let store = TaskStore()
    // 権限を戻して「保存は物理的に可能」にしてから、それでも書かないことを見る。
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    _ = try store.add(TaskDraft(title: "新しい"))

    XCTAssertEqual(try Data(contentsOf: url), Data(corruptJSON.utf8), "退避できなかった原本は潰さない")
  }
}
