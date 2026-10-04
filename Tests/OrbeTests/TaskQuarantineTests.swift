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
    #"{"id":\#(id),"title":"t\#(id)","status":"todo","priority":"medium","#
      + #""memo":"","createdAt":"2027-01-15T08:00:00.000Z"}"#
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

  /// 空の一覧でも、1 未満の採番位置からは 1 から振る ID を振れない（振れば次の起動で自分のファイルを弾く）。
  func testNextIdBelowOneIsQuarantinedEvenWithNoTasks() throws {
    try assertQuarantined(#"{"version":1,"nextId":0,"tasks":[]}"#, "1 未満の採番位置")
  }

  private func taskJSON(id: Int, links: String) -> String {
    String(taskJSON(id: id).dropLast()) + #","links":[\#(links)]}"#
  }

  private func file(_ tasks: [String]) -> String {
    #"{"version":1,"nextId":\#(tasks.count + 1),"tasks":[\#(tasks.joined(separator: ","))]}"#
  }

  /// 結び付きは書かれたとおりに読む（下の退避のテストが、壊れた JSON ではなく結び付きの規則で
  /// 退避していることの対照でもある）。
  func testDistinctLinksLoadAsWritten() throws {
    try Data(
      file([
        taskJSON(id: 1, links: #"{"kind":"issue","repo":"O/N","number":7}"#),
        taskJSON(id: 2, links: #"{"kind":"pr","repo":"o/n","number":8}"#),
      ]).utf8
    ).write(to: tasksFile())

    let loaded = try XCTUnwrap(TaskPersistence.load())

    XCTAssertTrue(try quarantineFiles().isEmpty)
    XCTAssertEqual(
      loaded.tasks.map { $0.links.map(\.item.text) }, [["o/n#7"], ["o/n#8"]], "repo は小文字で持つ")
    XCTAssertEqual(loaded.tasks.map { $0.links.map(\.kind) }, [[.issue], [.pr]])
  }

  /// 同じ項目（リポジトリ＋番号。種別と大小文字は問わない）が 2 つのタスクに付いた原本は、
  /// ストアの不変条件が守れないので退避する。
  func testAnItemLinkedToTwoTasksIsQuarantined() throws {
    let issue = #"{"kind":"issue","repo":"o/n","number":7}"#
    let sameItemAsPR = #"{"kind":"pr","repo":"O/N","number":7}"#
    try assertQuarantined(
      file([taskJSON(id: 1, links: issue), taskJSON(id: 2, links: sameItemAsPR)]),
      "2 つのタスクに付いた同じ項目")
  }

  func testTheSameItemTwiceInOneTaskIsQuarantined() throws {
    let twice = #"{"kind":"issue","repo":"o/n","number":7},{"kind":"pr","repo":"o/n","number":7}"#
    try assertQuarantined(file([taskJSON(id: 1, links: twice)]), "1 つのタスクに重複した項目")
  }

  func testAnUnreadableLinkIsQuarantined() throws {
    for (link, reason) in [
      (#"{"kind":"issue","repo":"orbe","number":7}"#, "owner/name の形でないリポジトリ"),
      (#"{"kind":"issue","repo":"o/n","number":0}"#, "1 未満の番号"),
      (#"{"kind":"discussion","repo":"o/n","number":7}"#, "issue / pr 以外の種別"),
    ] {
      try assertQuarantined(file([taskJSON(id: 1, links: link)]), reason)
      for quarantined in try quarantineFiles() {
        try FileManager.default.removeItem(at: quarantined)
      }
    }
  }

  /// u1 で書かれた最小の tasks.json（今の必須フィールドだけ）は、後の版でも読める。
  ///
  /// 壊れると何が起きるか: 後の単位がタスクに既定値付きの非 Optional フィールドを足すと、合成された
  /// decode が欠けたキーで失敗し、更新した全利用者の tasks.json が初回起動で丸ごと退避されて一覧が
  /// 空で始まる。この fixture は u1 の形で凍結しておく（足したフィールドに合わせて書き換えない）。
  func testMinimalU1FileStillLoads() throws {
    let u1 = """
      {"version":1,"nextId":5,"tasks":[\
      {"id":3,"title":"後","status":"done","priority":"low","memo":"","createdAt":"2027-01-15T08:00:00.000Z"},\
      {"id":1,"title":"先","status":"todo","priority":"medium","memo":"m","createdAt":"2027-01-15T08:00:00.000Z"}]}
      """
    try Data(u1.utf8).write(to: tasksFile())

    let loaded = try XCTUnwrap(TaskPersistence.load(), "u1 の最小形は読める")

    XCTAssertTrue(try quarantineFiles().isEmpty, "u1 の最小形を退避しない")
    XCTAssertEqual(loaded.nextId, 5)
    XCTAssertEqual(loaded.tasks.map(\.id), [3, 1], "列の順を保つ")
    XCTAssertEqual(loaded.tasks.map(\.status), [.done, .todo])
    XCTAssertEqual(loaded.tasks.last?.memo, "m")
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
