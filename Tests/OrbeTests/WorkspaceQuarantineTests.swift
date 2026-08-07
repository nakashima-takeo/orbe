import AppKit
import XCTest

@testable import Orbe

/// 読めなかった `workspaces.json` の退避と、退避できなかったときの保存停止を固定する。
///
/// 壊れると何が起きるか——原本を退避しないまま既定 workspace で起動すると、`newTab()` が打つ
/// `scheduleSave()` の `.atomic` write が約 1 秒後に原本を完全に潰す。ユーザーは workspace 構成
/// （タブ・分割ツリー・cwd・エージェントセッション・上書き設定）を、気づく機会が一度も無いまま
/// 復元不能に失う。退避に失敗したときに保存を止める assert が落ちれば、保全できていない原本を
/// 既定構成で潰す＝#85 が直した破壊がそのまま戻る。不在時に退避しない assert が落ちれば、
/// 初回起動のたびに意味のない退避物が積み上がる。
///
/// `WorkspacePersistence` 単体で固定し、実害は host でも出るので最後の 1 本だけ実
/// `WindowController` を起こす（L2）。
final class WorkspaceQuarantineTests: OrbeTestCase {

  /// ユーザー構成が入った、壊れた v3 JSON（末尾で切れている）。
  private let corruptJSON = """
    {"version":3,"activeWorkspace":0,"workspaces":[\
    {"name":"alpha","rootPath":"/tmp/alpha","activeTab":0,\
    "tabs":[{"tree":{"leaf":{"cwd":"/tmp/alpha"}}}]},\
    {"name":"bravo","rootPath":"/tmp/bravo","activeTab":0,"tabs":[{"tree":{"leaf":{}
    """

  /// 現在の版が受理しない version の、構造は妥当な JSON（将来の v4 相当）。
  private let futureVersionJSON = """
    {"version":999,"activeWorkspace":0,"workspaces":[\
    {"name":"alpha","rootPath":"/tmp/alpha","activeTab":0,"tabs":[{"tree":{"leaf":{}}}]}]}
    """

  /// state dir に残っている退避物（ハーネスが配る workspaces.json の隣）。
  private func quarantineFiles() throws -> [URL] {
    let dir = try workspacesFile().deletingLastPathComponent()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasPrefix("workspaces-broken-") && $0.hasSuffix(".json") }
      .sorted().map { dir.appendingPathComponent($0) }
  }

  /// 保存できることを見るための健全な構成。
  private func healthyFile() -> WorkspacesFile {
    WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "kept", rootPath: "/tmp/kept", activeTab: 0,
          tabs: [TabState(tree: .leaf(cwd: "/tmp/kept", agent: nil), explicitTitle: nil)])
      ])
  }

  // MARK: - persistence 単体（実ファイル）

  /// 構造破損の原本は、退避物としてバイト単位でそのまま残る（原位置からは消える）。
  func testCorruptFileIsQuarantinedWithOriginalBytes() throws {
    let url = try workspacesFile()
    try Data(corruptJSON.utf8).write(to: url)

    XCTAssertNil(WorkspacePersistence.load(), "壊れた JSON は load で nil（呼び出し側が既定 fallback）")

    let quarantined = try quarantineFiles()
    XCTAssertEqual(quarantined.count, 1, "壊れた原本は退避物としてちょうど 1 件残る")
    XCTAssertEqual(
      try Data(contentsOf: XCTUnwrap(quarantined.first)), Data(corruptJSON.utf8),
      "退避物は原本とバイト単位で一致する（読めないファイルもそのまま残す）")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: url.path),
      "原位置は空く（直後の save が新しい既定ファイルを作る＝二重に同じ内容を持たない）")
  }

  /// 非互換 version も構造破損と同じ退避経路を通る（version 4 を出したときに見直せる形で原本を残す）。
  func testIncompatibleVersionFileIsQuarantined() throws {
    let url = try workspacesFile()
    try Data(futureVersionJSON.utf8).write(to: url)

    XCTAssertNil(WorkspacePersistence.load(), "非互換 version は load で nil")

    let quarantined = try quarantineFiles()
    XCTAssertEqual(quarantined.count, 1, "非互換 version の原本も退避される（構造破損と同じ扱い）")
    XCTAssertEqual(
      try Data(contentsOf: XCTUnwrap(quarantined.first)), Data(futureVersionJSON.utf8),
      "退避物は原本とバイト単位で一致する")
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "原位置は空く")
  }

  /// ファイル不在（初回起動）は退避しない——毎起動でゴミが積み上がらない。
  func testMissingFileIsNotQuarantined() throws {
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: try workspacesFile().path), "前提: 原本は不在")

    XCTAssertNil(WorkspacePersistence.load(), "不在なら load は nil（初回起動の正常系）")

    XCTAssertEqual(try quarantineFiles().count, 0, "失う構成が無いので退避物を 1 件も作らない")
    // 不在を退避経路へ流すと、存在しない原本の move が失敗して退避ガードが立ち、
    // 初回起動のセッションが丸ごと保存されなくなる（退避物が出ないので気づけない）。
    let healthy = healthyFile()
    WorkspacePersistence.save(healthy)
    XCTAssertEqual(
      WorkspacePersistence.load(), healthy, "初回起動の保存は通常どおりディスクへ届く")
  }

  /// 空 workspaces は退避しない（失う構成がゼロ）。原本も原位置に残す。
  func testEmptyWorkspacesIsNotQuarantined() throws {
    let url = try workspacesFile()
    let empty = #"{"version":3,"activeWorkspace":0,"workspaces":[]}"#
    try Data(empty.utf8).write(to: url)

    XCTAssertNil(WorkspacePersistence.load(), "空 workspaces は load で nil（既定 1 workspace へ）")

    XCTAssertEqual(try quarantineFiles().count, 0, "失う workspace 構成がゼロなので退避しない")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.path), "原本は原位置に残る（move していない）")
  }

  /// 退避が走ると古い退避物は消え、残る 1 件は必ず今回の原本になる。
  func testQuarantineKeepsOnlyTheNewest() throws {
    let url = try workspacesFile()
    let dir = url.deletingLastPathComponent()
    let stale = dir.appendingPathComponent("workspaces-broken-19700101-000000.json")
    try Data("stale".utf8).write(to: stale)
    try Data(corruptJSON.utf8).write(to: url)

    XCTAssertNil(WorkspacePersistence.load())

    let quarantined = try quarantineFiles()
    XCTAssertEqual(quarantined.count, 1, "退避物は常に最新 1 件だけ")
    XCTAssertEqual(
      try Data(contentsOf: XCTUnwrap(quarantined.first)), Data(corruptJSON.utf8),
      "残るのは今回の原本（消えるのは常により古く価値の低い控え）")
  }

  /// 退避物の名前はソート可能なタイムスタンプ形式（値は固定しない・形だけ固定する）。
  func testFileNameIsSortableTimestamp() throws {
    try Data(corruptJSON.utf8).write(to: workspacesFile())

    XCTAssertNil(WorkspacePersistence.load())

    let name = try XCTUnwrap(quarantineFiles().first).lastPathComponent
    XCTAssertNotNil(
      name.range(of: #"^workspaces-broken-\d{8}-\d{6}\.json$"#, options: .regularExpression),
      "退避物の名前は workspaces-broken-<日時>.json（ソート可能で人が読める形）: \(name)")
  }

  /// 退避に失敗したセッションは `workspaces.json` へ一切書かない（保全できていない原本を潰さない）。
  func testSaveIsBlockedWhenQuarantineFails() throws {
    let url = try workspacesFile()
    let dir = url.deletingLastPathComponent()
    try Data(corruptJSON.utf8).write(to: url)

    // 退避（＝ディレクトリへの新しいエントリ作成）だけを失敗させる。
    // root で走ると権限が効かないので、プローブして効かない環境は skip する。
    let fm = FileManager.default
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    // 0555 のままだと endCase() の removeItem が失敗して caseDir が残る。
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
    let probe = dir.appendingPathComponent("probe")
    if (try? Data().write(to: probe)) != nil {
      try? fm.removeItem(at: probe)
      throw XCTSkip("ディレクトリ権限が効かない環境（root 等）では退避失敗を作れない")
    }

    XCTAssertNil(WorkspacePersistence.load(), "退避に失敗しても load は nil を返す（起動は続く）")

    // 権限を戻す＝「保存は物理的に可能」な状態にしてから、それでも書かないことを見る。
    // 戻さずに assert すると「書けないから残った」だけになり、ガードの有無を区別できない。
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    WorkspacePersistence.save(healthyFile())

    XCTAssertEqual(
      try Data(contentsOf: url), Data(corruptJSON.utf8),
      "退避できなかった原本は既定構成で潰さない（保全に失敗したら書かない）")
  }

  /// 一度退避に失敗して立ったガードは、次の `load()` が退避に成功した時点で解ける。
  ///
  /// ガードの**解除条件**を測る唯一のテスト。1 テスト内で `load()` を 2 回通すのは、解除を見るには
  /// 先にガードが立った状態が要るのに、保存先はテストごとに変わる（＝ガードはテストを跨げない）から。
  /// `load()` 冒頭のリセットが消えると、一度退避に失敗したプロセスは以後の退避成功後も永久に
  /// 保存しなくなる。
  func testGuardClearsWhenTheNextLoadQuarantinesSuccessfully() throws {
    let url = try workspacesFile()
    let dir = url.deletingLastPathComponent()
    try Data(corruptJSON.utf8).write(to: url)

    // 1 回目: 退避（＝ディレクトリへの新しいエントリ作成）だけを失敗させ、ガードを立てる。
    let fm = FileManager.default
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    // 0555 のままだと endCase() の removeItem が失敗して caseDir が残る。
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
    let probe = dir.appendingPathComponent("probe")
    if (try? Data().write(to: probe)) != nil {
      try? fm.removeItem(at: probe)
      throw XCTSkip(
        "ディレクトリ権限が効かない環境（root 等）では退避失敗を作れない"
          + "（退避成功後の保存は testSaveResumesAfterSuccessfulQuarantine が無条件に見る）")
    }
    XCTAssertNil(WorkspacePersistence.load(), "1 回目: 退避に失敗しても load は nil")

    // 2 回目: 権限を戻すと退避できる。原本は move に失敗して原位置に残っているので置き直さない
    // ——残っていること自体が「退避に失敗したら原本を守る」の証拠なので、前提として測る。
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    XCTAssertEqual(
      try Data(contentsOf: url), Data(corruptJSON.utf8), "前提: 退避に失敗した原本は原位置に残る")
    XCTAssertNil(WorkspacePersistence.load(), "2 回目: 退避が成功しても load は nil")
    XCTAssertEqual(try quarantineFiles().count, 1, "2 回目で原本が退避されている")

    let healthy = healthyFile()
    WorkspacePersistence.save(healthy)

    XCTAssertEqual(
      WorkspacePersistence.load(), healthy,
      "退避に成功した load がガードを解く（一度失敗したプロセスが永久に保存しなくならない）")
  }

  /// 退避に成功したら通常どおり保存する（ガードが立ちっぱなしにならない）。
  func testSaveResumesAfterSuccessfulQuarantine() throws {
    try Data(corruptJSON.utf8).write(to: workspacesFile())
    XCTAssertNil(WorkspacePersistence.load(), "前提: 退避が走る")

    let healthy = healthyFile()
    WorkspacePersistence.save(healthy)

    XCTAssertEqual(
      WorkspacePersistence.load(), healthy, "退避成功後の保存は通常どおりディスクへ届く")
  }

  // MARK: - 実 WindowController 起動（L2）

  /// 壊れた原本で起動すると、原本は退避物として残り、`workspaces.json` は既定構成で書き直される。
  /// これが #85 の実害そのもの——`flushSave()` で 1 秒のデバウンスを待たずに起動直後の保存を再現する。
  func testLaunchWithCorruptFileKeepsOriginalInQuarantine() throws {
    // 言語確定済み（初回言語選択 overlay を出さない）＋ PATH キャッシュ（ログインシェル同期 spawn を避ける）。
    AppStatePersistence.save(
      AppStateFile(cachedShellPath: "/usr/bin:/bin", preferredLanguage: "ja"))
    try Data(corruptJSON.utf8).write(to: workspacesFile())

    let wc = WindowController()
    wc.flushSave()

    XCTAssertEqual(wc.window.title, "default", "壊れた JSON では既定 workspace で起動する")
    let quarantined = try quarantineFiles()
    XCTAssertEqual(quarantined.count, 1, "起動直後の保存に潰される前に原本が退避されている")
    XCTAssertEqual(
      try Data(contentsOf: XCTUnwrap(quarantined.first)), Data(corruptJSON.utf8),
      "退避物は原本とバイト単位で一致する（手で rename すれば復旧できる）")
    XCTAssertEqual(
      WorkspacePersistence.load()?.workspaces.count, 1,
      "workspaces.json は既定構成で書き直されている（次回起動からは正常）")
  }
}
