import XCTest

@testable import Orbe

/// 実 FSEvents: 根の下の変化がパス集合として、git dir の中の変化は「git が変わった」だけとして、根の綴りで届く。
/// 壊れると外部変更が一つも拾えない（temp dir は `/var` が symlink で、実パスのまま比べると根に当たらない）、
/// `.git/objects` の churn で status を取り直し続ける、ビルド中に通知が出ない。
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
  }

  override func tearDownWithError() throws {
    watcher = nil
    repo.cleanup()
  }

  func testWorktreeChangesArriveAsRootSpelledPaths() throws {
    try repo.write("src/new.txt", "x\n")
    pumpMain(until: { !batches.isEmpty }, "書き込みの通知")
    let batch = try XCTUnwrap(batches.first)
    XCTAssertTrue(batch.paths.contains(repo.root + "/src/new.txt"), "根の綴りで届く: \(batch.paths)")
    XCTAssertFalse(batch.paths.contains { $0.hasPrefix("/private/") }, "実パスのままにしない")
    XCTAssertFalse(batch.scanAll)
  }

  /// git の操作は「git が変わった」だけを立て、パス集合には `.git` の中を入れない。`objects` の出入りだけでは
  /// 「git が変わった」にならない（直後の作業ツリーの変化と同じバッチに畳まれるので、そのバッチで見る）。
  func testGitOperationsRaiseGitChangedWithoutPaths() throws {
    XCTAssertTrue(
      GitRunner.shared.runSync(
        ["hash-object", "-w", "--stdin"], cwd: repo.dir.path, stdin: Data("blob\n".utf8)
      )
      .isSuccess)
    try repo.write("a.txt", "changed\n")
    pumpMain(until: { !batches.isEmpty }, "作業ツリーの変化")
    XCTAssertEqual(batches.map(\.gitChanged), [false], "objects だけの変化は git の変化ではない")
    batches.removeAll()

    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { batches.contains { $0.gitChanged } }, "index の変化")
    XCTAssertTrue(
      batches.allSatisfy { $0.paths.allSatisfy { !$0.contains("/.git/") } },
      "git dir の中はパスに出ない: \(batches)")
    batches.removeAll()

    XCTAssertTrue(repo.git(["commit", "-qm", "c"]).isSuccess)
    pumpMain(until: { batches.contains { $0.gitChanged } }, "HEAD / refs の変化")
  }

  /// 変わり続ける間も 1 秒に 1 回は出る（後追いだけだと飢餓する）。
  func testContinuousChangesStillFlushWithinTheMaximumDelay() throws {
    let start = Date()
    var writes = 0
    while Date().timeIntervalSince(start) < 1.6 {
      try repo.write("busy.txt", "\(writes)\n")
      writes += 1
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    pumpMain(until: { !batches.isEmpty }, "連続書き込みの通知")
    XCTAssertGreaterThan(writes, 20, "前提: デバウンス間隔より密に書き続けた")
    XCTAssertLessThan(
      Date().timeIntervalSince(start), 1.6 + RepoWatcher.maximumDelay + 0.5, "上限で強制的に出る")
  }
}
