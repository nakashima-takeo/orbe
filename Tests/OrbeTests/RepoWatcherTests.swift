import XCTest

@testable import Orbe

/// 実 FSEvents: 根の下の変化がパス集合として、git dir の中の変化は「git が変わった」だけとして、根の綴りで届く。
/// 壊れると外部変更が一つも拾えない（temp dir は `/var` が symlink で、実パスのまま比べると根に当たらない）、
/// `.git/objects` の churn で status を取り直し続ける。
final class RepoWatcherTests: OrbeTestCase {
  private var repo: TempGitRepo!
  private var batches: [RepoWatcher.Batch] = []
  private var watcher: RepoWatcher?

  override func setUpWithError() throws {
    repo = try TempGitRepo()
    XCTAssertTrue(repo.root.hasPrefix("/var/"), "前提: temp dir は symlink 経由の綴り（\(repo.root)）")
    let gitDir = repo.root + "/.git"
    watcher = RepoWatcher(roots: [repo.root, gitDir], gitDirs: [gitDir]) { [weak self] batch in
      self?.batches.append(batch)
    }
    XCTAssertNotNil(watcher)
    // fixture の初期 commit が残した変化が、監視を始めた後の最初の配達に混ざって届くことがある（FSEvents
    // の「今から」の境界は厳密ではない）。目印を 1 つ書いてその配達を待ち、以後のテストが自分の起こした
    // 変化だけを見るようにする——配達は起きた順なので、目印より前の変化はここで出尽くす。
    try repo.write(".orbe-watch-marker", "")
    pumpMain(until: { batches.contains { $0.paths.contains(repo.root + "/.orbe-watch-marker") } })
    batches.removeAll()
  }

  override func tearDownWithError() throws {
    watcher = nil
  }

  func testWorktreeChangesArriveAsRootSpelledPaths() throws {
    try repo.write("src/new.txt", "x\n")
    pumpMain(until: { !batches.isEmpty }, "書き込みの通知")
    let batch = try XCTUnwrap(batches.first)
    XCTAssertTrue(batch.paths.contains(repo.root + "/src/new.txt"), "根の綴りで届く: \(batch.paths)")
    XCTAssertFalse(batch.paths.contains { $0.hasPrefix("/private/") }, "実パスのままにしない")
    XCTAssertFalse(batch.scanAll)
  }

  /// git の操作は「git が変わった」だけを立て、パス集合には `.git` の中を入れない。objects（loose・
  /// multi-pack-index）・reflog・他の worktree の私有状態・submodule の objects や reflog・`.lock` の出入りだけでは
  /// 「git が変わった」にも「入れ子の git dir が変わった」にもならない——それだけではバッチが生まれないので、作業ツリーの
  /// 変化を 1 つ起こしてそのバッチ（畳まれる）で見る。
  func testGitOperationsRaiseGitChangedWithoutPaths() throws {
    // サブモジュールの git dir そのものの出入りは入れ子の変化なので、先に作って配達を済ませる。
    for dir in ["objects/ab", "logs", "fsmonitor--daemon/cookies"] {
      try FileManager.default.createDirectory(
        atPath: repo.root + "/.git/modules/sub/" + dir, withIntermediateDirectories: true)
    }
    try repo.write(".orbe-watch-marker", "again")
    pumpMain(until: { batches.contains { $0.paths.contains(repo.root + "/.orbe-watch-marker") } })
    batches.removeAll()
    XCTAssertTrue(
      GitRunner.shared.runSync(
        ["hash-object", "-w", "--stdin"], cwd: repo.dir.path, stdin: Data("blob\n".utf8)
      )
      .isSuccess)
    for noise in [
      "index.lock", "objects/pack/multi-pack-index", "logs/HEAD", "worktrees/other/index",
      "worktrees/other/HEAD", "modules/sub/objects/ab/cdef", "modules/sub/logs/HEAD",
      "modules/sub/index.lock", "modules/sub/fsmonitor--daemon/cookies/1-1",
    ] {
      try repo.write(".git/" + noise, "n\n")
    }
    try FileManager.default.removeItem(atPath: repo.root + "/.git/index.lock")
    try repo.write("a.txt", "changed\n")
    pumpMain(until: { !batches.isEmpty }, "作業ツリーの変化")
    XCTAssertEqual(batches.map(\.gitChanged), [false], "関係ない出入りは git の変化ではない")
    XCTAssertEqual(batches.map(\.nestedGitChanged), [false], "入れ子の git dir の変化でもない")
    batches.removeAll()

    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { batches.contains { $0.gitChanged } }, "index の変化")
    XCTAssertTrue(
      batches.allSatisfy { $0.paths.allSatisfy { !$0.contains("/.git/") } },
      "git dir の中はパスに出ない: \(batches)")
    XCTAssertFalse(batches.contains { $0.remoteRefsChanged }, "index は remote 追跡 ref ではない")
    batches.removeAll()

    XCTAssertTrue(repo.git(["commit", "-qm", "c"]).isSuccess)
    pumpMain(until: { batches.contains { $0.gitChanged } }, "HEAD / refs の変化")
    XCTAssertFalse(
      batches.contains { $0.remoteRefsChanged }, "HEAD とローカルのブランチは remote 追跡 ref ではない")
    batches.removeAll()

    XCTAssertTrue(repo.git(["tag", "t"]).isSuccess)
    XCTAssertTrue(repo.git(["pack-refs", "--all"]).isSuccess)
    pumpMain(until: { batches.contains { $0.gitChanged } }, "packed-refs の変化（loose ref が消える）")
    batches.removeAll()
    XCTAssertTrue(repo.git(["tag", "-d", "t"]).isSuccess)
    pumpMain(until: { batches.contains { $0.gitChanged } }, "packed な tag の削除は packed-refs だけが変わる")
  }

  /// git dir の中の判定を実時間ゼロで押さえる。とくに fsmonitor の cookie は git が status のたびに作って
  /// 消すので、拾うと自分の status が自分を呼び戻す閉路になる。
  func testGitDirFilterIgnoresGitsOwnReadSideEffects() {
    for ignored in [
      "/fsmonitor--daemon/cookies/93678-1", "/fsmonitor--daemon.ipc",
      "/objects/pack/multi-pack-index",
      "/objects/ab/cdef", "/logs/HEAD", "/worktrees/other/index",
      "/index.lock", "/packed-refs.lock", "/worktrees", "/objects",
      "/modules/sub/objects/ab/cdef", "/modules/sub/logs/HEAD", "/modules/sub/index.lock",
      "/modules/tools/sub/fsmonitor--daemon/cookies/1-1", "/modules/a/modules/b/objects/pack/x",
      "/modules/sub/worktrees/w/index",
    ] {
      XCTAssertNil(RepoWatcher.gitDirChange(ignored), ignored)
    }
    for state in [
      "/index", "/HEAD", "/ORIG_HEAD", "/refs/heads/main", "/packed-refs", "/reftable/tables.list",
      "/MERGE_HEAD", "/rebase-merge/done", "/sequencer/todo", "/AUTO_MERGE", "/some-new-state-file",
      "/refs/heads/logs",
    ] {
      XCTAssertEqual(
        RepoWatcher.gitDirChange(state), .state(remoteRefs: RepoWatcher.isRemoteRefChange(state)),
        state)
    }
    for nested in [
      "/modules/sub/index", "/modules/sub/HEAD", "/modules/tools/sub/refs/heads/main",
      "/modules/a/modules/b/index", "/modules/sub/ORIG_HEAD",
    ] {
      XCTAssertEqual(RepoWatcher.gitDirChange(nested), .nested, nested)
    }
    for ref in [
      "/refs/remotes/origin/main", "/refs/remotes", "/packed-refs", "/reftable/tables.list",
    ] {
      XCTAssertTrue(RepoWatcher.isRemoteRefChange(ref), ref)
    }
    for state in [
      "/HEAD", "/refs/heads/main", "/refs/tags/v1", "/index", "/FETCH_HEAD", "/ORIG_HEAD",
      "/MERGE_HEAD", "/rebase-merge/done",
    ] {
      XCTAssertFalse(RepoWatcher.isRemoteRefChange(state), state)
    }
  }

  /// 根より深い `<dir>/.git/` の下（作業ツリーの中に git dir を持つサブモジュール・入れ子のリポジトリ）の状態の変化は、
  /// パスにも親の git の変化にも出ず、「入れ子の git dir が変わった」として届く。その objects・`.lock` では届かない。根
  /// 自身の `.git/` は根だけを見る監視では捨てる（git dir の監視が受け持つ）。
  func testANestedGitDirInTheWorkingTreeArrivesAsItsOwnChange() throws {
    try repo.write("inner/x.txt", "x\n")
    for args in [
      ["init", "-q", "inner"], ["-C", "inner", "add", "x.txt"],
      ["-C", "inner", "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "x"],
    ] {
      XCTAssertTrue(repo.git(args).isSuccess, "\(args)")
    }
    var rootBatches: [RepoWatcher.Batch] = []
    let rootOnly = RepoWatcher(roots: [repo.root], gitDirs: []) { rootBatches.append($0) }
    XCTAssertNotNil(rootOnly)
    try repo.write(".orbe-watch-marker-2", "")
    pumpMain(
      until: { rootBatches.contains { $0.paths.contains(repo.root + "/.orbe-watch-marker-2") } })
    rootBatches.removeAll()

    try repo.write(".git/some-state", "s\n")
    try repo.write("inner/.git/objects/ab/cdef", "o\n")
    try repo.write("inner/.git/index.lock", "l\n")
    try repo.write("b.txt", "b\n")
    pumpMain(until: { rootBatches.contains { $0.paths.contains(repo.root + "/b.txt") } })
    XCTAssertFalse(rootBatches.contains { $0.nestedGitChanged || $0.gitChanged }, "\(rootBatches)")
    rootBatches.removeAll()
    try FileManager.default.removeItem(atPath: repo.root + "/inner/.git/index.lock")

    try repo.write("inner/x.txt", "y\n")
    XCTAssertTrue(repo.git(["-C", "inner", "commit", "-qam", "y"]).isSuccess)
    pumpMain(until: { rootBatches.contains { $0.nestedGitChanged } }, "中のコミット")
    XCTAssertFalse(rootBatches.contains { $0.gitChanged || $0.remoteRefsChanged })
    XCTAssertTrue(
      rootBatches.allSatisfy { $0.paths.allSatisfy { !$0.contains("/.git/") } }, "\(rootBatches)")
    withExtendedLifetime(rootOnly) {}
  }

  /// linked worktree の根は、自分の gitDir（commonDir の中）の変化は拾い、隣の worktree の私有状態では
  /// 取り直さない。
  func testLinkedWorktreeIgnoresSiblingWorktreeState() throws {
    let linked = repo.addWorktree("wt", branch: "feat/wt")
    let sibling = repo.addWorktree("other", branch: "feat/other")
    let gitDir = repo.root + "/.git/worktrees/wt"
    let commonDir = repo.root + "/.git"
    var linkedBatches: [RepoWatcher.Batch] = []
    let watcher = RepoWatcher(roots: [linked, gitDir, commonDir], gitDirs: [commonDir, gitDir]) {
      linkedBatches.append($0)
    }
    XCTAssertNotNil(watcher)
    try repo.write(".orbe-watch-marker", "", in: linked)
    pumpMain(until: { linkedBatches.contains { $0.paths.contains(linked + "/.orbe-watch-marker") } }
    )
    linkedBatches.removeAll()

    try repo.write("a.txt", "sibling\n", in: sibling)
    XCTAssertTrue(repo.git(["add", "a.txt"], in: sibling).isSuccess)
    try repo.write("mine.txt", "m\n", in: linked)
    pumpMain(until: { !linkedBatches.isEmpty })
    XCTAssertEqual(linkedBatches.map(\.gitChanged), [false], "隣の worktree の index では取り直さない")
    linkedBatches.removeAll()

    XCTAssertTrue(repo.git(["add", "mine.txt"], in: linked).isSuccess)
    pumpMain(until: { linkedBatches.contains { $0.gitChanged } }, "自分の index（commonDir の中）は拾う")
    withExtendedLifetime(watcher) {}
  }
}
