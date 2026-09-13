import XCTest

@testable import Orbe

/// 実 git 層: `gitDir` の解決と観測（status・index の OID・blob）。壊れると linked worktree で index の変化を
/// 監視できない、status がユーザー設定で変わる、baseline が別の版になる。
final class GitRepoObserveTests: OrbeTestCase {
  private var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  override func tearDownWithError() throws {
    repo.cleanup()
  }

  /// 本体では `<root>/.git`、linked worktree では `<commonDir>/worktrees/<name>`。綴りは git のまま。
  func testGitDirResolvesForMainAndLinkedWorktrees() throws {
    let main = try repo.open()
    XCTAssertEqual(
      GitWorktreeRoot.normalizedPath(main.gitDir), repo.root + "/.git")
    XCTAssertEqual(GitWorktreeRoot.normalizedPath(main.commonDir), repo.root + "/.git")

    let linkedRoot = repo.addWorktree("wt", branch: "feat/wt")
    var linked: GitRepo?
    let done = expectation(description: "open linked")
    GitRepo.open(cwd: linkedRoot) {
      linked = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    let opened = try XCTUnwrap(linked)
    XCTAssertEqual(GitWorktreeRoot.normalizedPath(opened.root), linkedRoot)
    XCTAssertEqual(GitWorktreeRoot.normalizedPath(opened.gitDir), repo.root + "/.git/worktrees/wt")
    XCTAssertEqual(GitWorktreeRoot.normalizedPath(opened.commonDir), repo.root + "/.git")
  }

  /// status は M / A / U / 競合を相対パスで返し、未追跡ディレクトリは前方一致で引ける。
  /// ユーザーの `status.showUntrackedFiles=no` があっても未追跡は出る。
  func testStatusReflectsTheWorktreeRegardlessOfUserSettings() throws {
    let git = try repo.open()
    XCTAssertTrue(repo.git(["config", "status.showUntrackedFiles", "no"]).isSuccess)
    try repo.write("a.txt", "changed\n")
    try repo.write("b.txt", "new\n")
    XCTAssertTrue(repo.git(["add", "b.txt"]).isSuccess)
    try repo.write("notes.txt", "n\n")
    try repo.write("dir/inner.txt", "i\n")

    let status = try XCTUnwrap(self.status(git))
    XCTAssertEqual(status.badge(of: "a.txt"), .modified)
    XCTAssertEqual(status.badge(of: "b.txt"), .added)
    XCTAssertEqual(status.badge(of: "notes.txt"), .untracked)
    XCTAssertEqual(status.badge(of: "dir/inner.txt"), .untracked, "未追跡ディレクトリの中")
    XCTAssertEqual(status.untrackedDirectories, ["dir"])
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: repo.root + "/.git/index.lock"), "観測は index を書き換えない")
  }

  /// index の OID は `git add` で変わり、blob はその版の生の中身。index に無い・競合中は引けない。
  func testIndexEntriesAndBlobFollowTheIndex() throws {
    let git = try repo.open()
    let before = try XCTUnwrap(indexEntries(git, ["a.txt", "missing.txt"]))
    XCTAssertEqual(before.count, 1)
    let oid = try XCTUnwrap(before["a.txt"])
    XCTAssertEqual(blob(git, oid).flatMap { String(data: $0, encoding: .utf8) }, "one\n")

    try repo.write("a.txt", "two\n")
    XCTAssertEqual(
      try XCTUnwrap(indexEntries(git, ["a.txt"]))["a.txt"], oid, "作業ツリーの編集では index は変わらない")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    let after = try XCTUnwrap(indexEntries(git, ["a.txt"]))["a.txt"]
    XCTAssertNotEqual(after, oid)
    XCTAssertEqual(
      blob(git, try XCTUnwrap(after)).flatMap { String(data: $0, encoding: .utf8) }, "two\n")
    XCTAssertEqual(try XCTUnwrap(indexEntries(git, [])), [:], "空の問い合わせは空")
    XCTAssertNil(blob(git, "0000000000000000000000000000000000000000"), "無い OID は nil")
  }

  private func status(_ git: GitRepo) -> GitStatus? {
    var result: GitStatus?
    let done = expectation(description: "status")
    git.status {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return result
  }

  private func indexEntries(_ git: GitRepo, _ paths: [String]) -> [String: String]? {
    var result: [String: String]?
    let done = expectation(description: "ls-files")
    git.indexEntries(relativePaths: paths) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return result
  }

  private func blob(_ git: GitRepo, _ oid: String) -> Data? {
    var result: Data?
    let done = expectation(description: "cat-file")
    git.blob(oid: oid) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return result
  }
}
