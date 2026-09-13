import XCTest

@testable import Orbe

/// 根のサービス（実 git・実 FSEvents）: 管理下かの判定、status とバッジの追従、baseline（index 版）の追従、
/// 観測者の関心の和集合、一覧と新規作成、寿命。
///
/// 壊れると何が起きるか。symlink 経由の綴りで管理外と判定されると git バッジが一切出ない。status が古いままだと
/// 外で `git add` しても印が変わらない。baseline が追従しないとガターの差分が commit 後も残る。
@MainActor
final class RootFilesTests: OrbeTestCase {
  private var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  override func tearDownWithError() throws {
    repo.cleanup()
  }

  /// 通知を記録する観測者。
  private final class Recorder: RootFilesObserver {
    var changes: [RootFiles.Change] = []
    var statusChanges = 0
    var baselineChanges: [URL] = []
    func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {
      changes.append(change)
    }
    func rootFilesStatusDidChange(_ files: RootFiles) { statusChanges += 1 }
    func rootFiles(_ files: RootFiles, baselineDidChange url: URL) { baselineChanges.append(url) }
  }

  // MARK: - 根の判定

  func testManagedRootIsRecognizedThroughSymlinkSpelling() throws {
    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    files.addObserver(recorder)
    pumpMain(until: { files.status != nil }, "status の初回取得")
    XCTAssertNotNil(files.repo)
    XCTAssertEqual(recorder.statusChanges, 1)
    XCTAssertNil(files.status?.badge(of: "a.txt"), "clean")
  }

  func testUnmanagedRootHasNoGitState() throws {
    let plain = repo.dir.appendingPathComponent("plain", isDirectory: true)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    // 根は「.git を持つ最初の祖先」なので、管理外を作るには repo の外に置く。
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbe-plain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let root = GitWorktreeRoot.normalizedPath(outside.path)
    let files = RootFiles(root: root)
    let recorder = Recorder()
    files.addObserver(recorder, interest: outside.appendingPathComponent("x.txt"))

    try files.createFile(at: outside.appendingPathComponent("x.txt"))
    pumpMain(until: { !recorder.changes.isEmpty }, "管理外でも監視は働く")
    XCTAssertNil(files.repo)
    XCTAssertNil(files.status)
    XCTAssertEqual(recorder.statusChanges, 0)
    XCTAssertEqual(try files.entries(of: outside).map(\.name), ["x.txt"])
  }

  /// `.git` はあるが git が別の toplevel を返す根（cwd が `.git` の中）は管理外。
  func testRootInsideTheGitDirectoryIsUnmanaged() throws {
    let inside = repo.root + "/.git"
    try FileManager.default.createDirectory(
      atPath: inside + "/.git", withIntermediateDirectories: true)
    // 解決の完了は、同じ runner の barrier（先に積んだ読み取りの完了を待つ）が返ることで知る。
    let runner = GitRunner()
    let files = RootFiles(root: inside, runner: runner)
    let settled = expectation(description: "rev-parse が返った")
    runner.run(["version"], cwd: inside, lane: .exclusive) { _ in settled.fulfill() }
    wait(for: [settled], timeout: 20)
    XCTAssertNil(files.repo, "git の toplevel は repo 自身で、根と一致しない")
    XCTAssertNil(files.status)
  }

  // MARK: - status と監視

  func testStatusFollowsExternalWritesAndGitOperations() throws {
    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    files.addObserver(recorder)
    pumpMain(until: { files.status != nil })

    try repo.write("a.txt", "changed\n")
    pumpMain(until: { files.status?.badge(of: "a.txt") == .modified }, "外部の書き込みで M")
    XCTAssertTrue(
      recorder.changes.contains { $0.includes(repo.root + "/a.txt") }, "ファイルの変化はパス集合で届く")

    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "c"]).isSuccess)
    pumpMain(until: { files.status?.badge(of: "a.txt") == nil }, "commit で clean")

    try repo.write("dir/inner.txt", "i\n")
    pumpMain(until: { files.status?.badge(of: "dir/inner.txt") == .untracked }, "未追跡ディレクトリの中は U")
  }

  /// linked worktree の根で、本体側にある index が変われば拾う。
  func testLinkedWorktreeObservesItsIndexInTheMainRepository() throws {
    let linkedRoot = repo.addWorktree("wt", branch: "feat/wt")
    let files = RootFiles(root: linkedRoot)
    let recorder = Recorder()
    files.addObserver(recorder, interest: URL(fileURLWithPath: linkedRoot + "/a.txt"))
    pumpMain(until: { files.baseline(for: URL(fileURLWithPath: linkedRoot + "/a.txt")) == "one\n" })

    try repo.write("a.txt", "two\n", in: linkedRoot)
    XCTAssertTrue(repo.git(["add", "a.txt"], in: linkedRoot).isSuccess)
    pumpMain(
      until: { files.baseline(for: URL(fileURLWithPath: linkedRoot + "/a.txt")) == "two\n" },
      "本体側の index の変化")
    XCTAssertEqual(recorder.baselineChanges.count, 2)
  }

  // MARK: - baseline

  func testBaselineFollowsTheIndexAndDropsWhenRemovedFromIt() throws {
    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    let url = repo.url("a.txt")
    files.addObserver(recorder, interest: url)
    pumpMain(until: { files.baseline(for: url) == "one\n" }, "初回取得")
    XCTAssertEqual(recorder.baselineChanges, [url])

    try repo.write("a.txt", "two\n")
    pumpMain(until: { files.status?.badge(of: "a.txt") == .modified })
    XCTAssertEqual(files.baseline(for: url), "one\n", "作業ツリーの編集では index 版は変わらない")
    XCTAssertEqual(recorder.baselineChanges.count, 1, "OID が同じなら取り直さない")

    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { files.baseline(for: url) == "two\n" }, "git add で追従")
    XCTAssertTrue(repo.git(["rm", "--cached", "-q", "a.txt"]).isSuccess)
    pumpMain(until: { files.baseline(for: url) == nil }, "index から消えれば nil")
    XCTAssertEqual(recorder.baselineChanges.count, 3)

    let untracked = repo.url("nope.txt")
    try repo.write("nope.txt", "u\n")
    files.addObserver(Recorder(), interest: untracked)
    pumpMain(until: { files.status?.badge(of: "nope.txt") == .untracked })
    XCTAssertNil(files.baseline(for: untracked), "未追跡は baseline 無し")
  }

  /// 関心は観測者に紐づく——同じファイルを 2 つが追い、片方が消えても残った方の baseline は追従し続ける。
  func testInterestIsTheUnionOfLivingObservers() throws {
    let files = RootFiles(root: repo.root)
    let url = repo.url("a.txt")
    var first: Recorder? = Recorder()
    let second = Recorder()
    files.addObserver(first!, interest: url)
    files.addObserver(second, interest: url)
    pumpMain(until: { files.baseline(for: url) == "one\n" })
    XCTAssertEqual(second.baselineChanges, [url], "両方に届く")

    first = nil
    try repo.write("a.txt", "two\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { files.baseline(for: url) == "two\n" }, "残った観測者の関心で追従する")
    XCTAssertEqual(second.baselineChanges.count, 2)

    files.removeObserver(second)
    XCTAssertNil(files.baseline(for: url), "関心が無くなればキャッシュを捨てる")
  }

  // MARK: - 一覧と新規作成

  func testEntriesAndCreation() throws {
    let files = RootFiles(root: repo.root)
    let dir = URL(fileURLWithPath: repo.root)
    try repo.write(".hidden", "h\n")
    try files.createDirectory(at: dir.appendingPathComponent("Sub"))
    try files.createFile(at: dir.appendingPathComponent("b.txt"))
    try FileManager.default.createSymbolicLink(
      at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("Sub"))

    let entries = try files.entries(of: dir)
    XCTAssertEqual(
      entries.map(\.name), [".hidden", "a.txt", "b.txt", "link", "Sub"], "名前順（大小無視）・.git は出ない")
    XCTAssertEqual(entries.map(\.isDirectory), [false, false, false, false, true], "symlink は辿らない")
    XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("b.txt")), Data(), "空ファイル")

    XCTAssertThrowsError(try files.createFile(at: dir.appendingPathComponent("b.txt"))) {
      XCTAssertEqual($0 as? RootFiles.Error, .alreadyExists(dir.appendingPathComponent("b.txt")))
    }
    XCTAssertThrowsError(try files.createDirectory(at: dir.appendingPathComponent("Sub")))
    XCTAssertThrowsError(
      try files.createFile(at: dir.appendingPathComponent("no/such/x.txt")), "中間ディレクトリは作らない")
  }

  // MARK: - 寿命

  func testSharedInstanceLivesWhileHeld() throws {
    var held: RootFiles? = RootFiles.shared(for: repo.root)
    weak let observed = held
    XCTAssertTrue(RootFiles.shared(for: repo.root) === held, "生きていれば同じもの")
    held = nil
    XCTAssertNil(observed, "離せば消える（監視も止まる）")
    let again = RootFiles.shared(for: repo.root)
    XCTAssertFalse(again === observed)
  }
}
