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
    // 解決の完了は、同じ runner の barrier（先に積んだ読み取りの完了を待つ）が返ることで知る——
    // `GitRepo.open` が `.read` レーンに載っていることに依存する（`.independent` へ移すとここは待たない）。
    let runner = GitRunner()
    let files = RootFiles(root: inside, runner: runner)
    let settled = expectation(description: "rev-parse が返った")
    runner.run(["version"], cwd: inside, lane: .exclusive) { _ in settled.fulfill() }
    wait(for: [settled], timeout: 20)
    XCTAssertNil(files.repo, "git の toplevel は repo 自身で、根と一致しない")
    XCTAssertNil(files.status)
  }

  /// `.git` はあるが git が失敗する根（壊れた `.git` ファイル）も管理外。
  func testRootWithABrokenGitFileIsUnmanaged() throws {
    let broken = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbe-broken-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: broken) }
    try "gitdir: /nonexistent/orbe/.git\n".write(
      to: broken.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    let root = GitWorktreeRoot.normalizedPath(broken.path)
    XCTAssertEqual(GitWorktreeRoot.root(of: root), root, "前提: 根の規則はこの `.git` を根と見る")
    let runner = GitRunner()
    let files = RootFiles(root: root, runner: runner)
    let settled = expectation(description: "rev-parse が返った")
    runner.run(["version"], cwd: root, lane: .exclusive) { _ in settled.fulfill() }
    wait(for: [settled], timeout: 20)
    XCTAssertNil(files.repo)
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
    let gitDir = repo.root + "/.git"
    XCTAssertTrue(
      recorder.changes.allSatisfy { change in
        guard case .paths(let paths) = change else { return true }
        return paths.allSatisfy { $0 != gitDir && !$0.hasPrefix(gitDir + "/") }
      }, "根の監視は .git の中をパス集合に載せない: \(recorder.changes)")

    try repo.write("dir/inner.txt", "i\n")
    pumpMain(until: { files.status?.badge(of: "dir/inner.txt") == .untracked }, "未追跡ディレクトリの中は U")
  }

  /// 「status が変わった」は取り直しの結果が前と違うときだけ出る。変化を起こしても status が同じなら鳴らない。
  /// 取り直しは根ごとに直列なので、後に起こした変化の通知が届いた時点で前の取り直しは終わっている。
  func testStatusNotificationFiresOnlyWhenTheResultDiffers() throws {
    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    files.addObserver(recorder)
    pumpMain(until: { files.status != nil })
    try repo.write("a.txt", "changed\n")
    pumpMain(until: { files.status?.badge(of: "a.txt") == .modified })
    XCTAssertEqual(recorder.statusChanges, 2)

    let seen = recorder.changes.count
    try repo.write("a.txt", "changed again\n")
    pumpMain(
      until: { recorder.changes.dropFirst(seen).contains { $0.includes(repo.root + "/a.txt") } },
      "変化は届く")
    try repo.write("b.txt", "new\n")
    pumpMain(until: { files.status?.badge(of: "b.txt") == .untracked })
    XCTAssertTrue(repo.git(["add", "b.txt"]).isSuccess)
    pumpMain(until: { files.status?.badge(of: "b.txt") == .added })
    XCTAssertEqual(recorder.statusChanges, 4, "M のままの書き直しでは鳴らない（M → U → A の 3 回だけ）")
  }

  /// 根が git 管理下と分かる前（解決は非同期）に起きた変化も落とさない。
  func testChangesDuringRootResolutionAreNotLost() throws {
    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    files.addObserver(recorder)
    try repo.write("early.txt", "e\n")
    pumpMain(
      until: { recorder.changes.contains { $0.includes(repo.root + "/early.txt") } }, "解決前の変化")
    pumpMain(until: { files.status?.badge(of: "early.txt") == .untracked })
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
    let untrackedObserver = Recorder()
    files.addObserver(untrackedObserver, interest: untracked)
    pumpMain(until: { files.status?.badge(of: "nope.txt") == .untracked })
    XCTAssertNil(files.baseline(for: untracked), "未追跡は baseline 無し")
  }

  /// 観測者が消えれば関心も消える——次に観測者が出入りしたときに刈られ、baseline のキャッシュも捨てる。
  func testADeadObserversInterestIsPruned() throws {
    let files = RootFiles(root: repo.root)
    let url = repo.url("a.txt")
    var only: Recorder? = Recorder()
    files.addObserver(only!, interest: url)
    pumpMain(until: { files.baseline(for: url) == "one\n" })

    only = nil
    let bystander = Recorder()
    files.addObserver(bystander)
    XCTAssertNil(files.baseline(for: url), "死んだ観測者の関心は刈られる")

    var another: Recorder? = Recorder()
    files.addObserver(another!, interest: url)
    pumpMain(until: { files.baseline(for: url) == "one\n" })
    another = nil
    try repo.write("b.txt", "b\n")
    pumpMain(until: { files.baseline(for: url) == nil }, "観測者の出入りが無くても、次の取り直しで消える")
  }

  /// 競合中（stage 0 が無い）と UTF-8 でない index 版は baseline 無し。status には競合・A として出る。
  func testConflictedAndNonUTF8FilesHaveNoBaseline() throws {
    XCTAssertTrue(repo.git(["checkout", "-qb", "other"]).isSuccess)
    try repo.write("a.txt", "other\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "other"]).isSuccess)
    XCTAssertTrue(repo.git(["checkout", "-q", "main"]).isSuccess)
    try repo.write("a.txt", "main\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "main"]).isSuccess)
    XCTAssertFalse(repo.git(["merge", "other"]).isSuccess, "前提: 競合する")
    try Data([0xFF, 0xFE, 0x00]).write(to: repo.url("bin.dat"))
    XCTAssertTrue(repo.git(["add", "bin.dat"]).isSuccess)

    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    files.addObserver(recorder, interest: repo.url("a.txt"))
    files.addObserver(recorder, interest: repo.url("bin.dat"))
    pumpMain(until: { files.status != nil })
    XCTAssertEqual(files.status?.badge(of: "a.txt"), .conflicted)
    XCTAssertEqual(files.status?.badge(of: "bin.dat"), .added)
    XCTAssertNil(files.baseline(for: repo.url("a.txt")), "競合中は index 版が定まらない")
    XCTAssertNil(files.baseline(for: repo.url("bin.dat")), "UTF-8 でない版は使わない")
    XCTAssertEqual(recorder.baselineChanges, [], "無いものの初回取得は通知しない")
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

    let broken = dir.appendingPathComponent("broken")
    try FileManager.default.createSymbolicLink(
      at: broken, withDestinationURL: dir.appendingPathComponent("nowhere"))

    let entries = try files.entries(of: dir)
    XCTAssertEqual(
      entries.map(\.name), [".hidden", "a.txt", "b.txt", "broken", "link", "Sub"],
      "名前順（大小無視）・.git は出ない")
    XCTAssertEqual(
      entries.map(\.isDirectory), [false, false, false, false, false, true], "symlink は辿らない")
    XCTAssertEqual(
      entries.map(\.url.path), entries.map { dir.appendingPathComponent($0.name).path })
    XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("b.txt")), Data(), "空ファイル")

    XCTAssertThrowsError(try files.createFile(at: broken), "壊れた symlink は「在る」（リンク先へ書かない）") {
      XCTAssertEqual($0 as? RootFiles.Error, .alreadyExists(broken))
    }
    XCTAssertThrowsError(try files.createDirectory(at: broken)) {
      XCTAssertEqual($0 as? RootFiles.Error, .alreadyExists(broken))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: dir.appendingPathComponent("nowhere").path))

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
    XCTAssertTrue(RootFiles.shared(for: repo.root) === again, "解放後は登録簿に載り直す")
  }
}
