import XCTest

@testable import Orbe

/// 実 git 層: worktree の「status の件数」と「停止している git 操作」を確かめる。
///
/// 中心は **rebase 途中の worktree が安全群へ入らない**ことの直接の証拠。コンフリクトの無い停止点では
/// `status --porcelain` が空になるので、status だけを見ていた頃は初期チェック済みのまま消えていた。
/// gitdir 直下の管理エントリを読めば、subprocess を 1 本も増やさずに停止中だと分かる。
final class GitWorktreeOperationTests: OrbeTestCase {
  private var dir: URL!
  private var repo: GitRepo!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-op-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    XCTAssertTrue(git(["init", "-q", "-b", "main"]).isSuccess)
    XCTAssertTrue(git(["config", "user.email", "t@example.com"]).isSuccess)
    XCTAssertTrue(git(["config", "user.name", "t"]).isSuccess)
    try write(dir.path, "a.txt", "x")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "init"]).isSuccess)
    repo = try open()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  // MARK: - status の件数

  /// 行の語彙（`未コミット N ファイル` / `untracked N ファイル`）が、削除の関門と**同じ 1 本の出力**から出る。
  func testStatusCountsSplitTrackedAndUntracked() throws {
    let path = try addWorktree("wt", branch: "feat/wt")
    XCTAssertEqual(try statusCounts(path), GitWorktreeStatusCounts(modified: 0, untracked: 0))

    try write(path, "a.txt", "dirty")
    try write(path, "memo.txt", "note")
    try write(path, "memo2.txt", "note")

    XCTAssertEqual(try statusCounts(path), GitWorktreeStatusCounts(modified: 1, untracked: 2))
  }

  /// **確認できなかったら clean でない側に倒す**契約は件数 API でも変わらない（nil と 0 件を混ぜない）。
  func testStatusCountsAreNilWhenGitFails() throws {
    XCTAssertNil(try statusCounts(dir.appendingPathComponent("nowhere").path))
  }

  // MARK: - 停止している git 操作

  /// コンフリクトで停止した rebase を検知する。
  func testConflictedRebaseIsDetected() throws {
    let path = try addWorktree("wt", branch: "feat/conflict")
    try makeDivergingCommits(at: path)
    XCTAssertFalse(gitIn(path, ["rebase", "main"]).isSuccess, "前提: コンフリクトで停止する")

    XCTAssertEqual(GitWorktreeOperationProbe.detect(worktreeAt: path), .inProgress(.rebase))
  }

  /// **status が clean な停止点でも検知する。これが塞いだ穴そのもの。**
  /// `--exec false` は各コミットの適用後に失敗するコマンドを挟む＝作業ツリーは clean なまま停止する。
  func testRebaseStoppedWithCleanStatusIsStillDetected() throws {
    let path = try addWorktree("wt", branch: "feat/rebase")
    try write(path, "b.txt", "1")
    XCTAssertTrue(gitIn(path, ["add", "-A"]).isSuccess)
    XCTAssertTrue(gitIn(path, ["commit", "-qm", "c1"]).isSuccess)
    XCTAssertFalse(gitIn(path, ["rebase", "--exec", "false", "main"]).isSuccess)

    XCTAssertEqual(
      try statusCounts(path), GitWorktreeStatusCounts(modified: 0, untracked: 0),
      "前提: 停止していても status は空＝status ベースの関門だけなら通ってしまう")
    XCTAssertEqual(
      GitWorktreeOperationProbe.detect(worktreeAt: path), .inProgress(.rebase),
      "gitdir を読めば停止中だと分かる")
  }

  /// `MERGE_HEAD` は merge として名乗る（rebase と言い張らない——`git rebase --abort` を打ちに行かせない）。
  func testStoppedMergeIsDetectedAsMerge() throws {
    let path = try addWorktree("wt", branch: "feat/merge")
    try makeDivergingCommits(at: path)
    XCTAssertFalse(gitIn(path, ["merge", "main"]).isSuccess, "前提: コンフリクトで停止する")

    XCTAssertEqual(GitWorktreeOperationProbe.detect(worktreeAt: path), .inProgress(.merge))
  }

  /// 通常の worktree を誤検知しない（検知のせいで安全群が痩せない）。
  func testQuietWorktreeReportsNoOperation() throws {
    let path = try addWorktree("wt", branch: "feat/quiet")
    XCTAssertEqual(GitWorktreeOperationProbe.detect(worktreeAt: path), .none)
  }

  /// gitdir はリンク worktree（`.git` がファイル）でも本体（ディレクトリ）でも解決できる。
  func testGitDirResolvesForBothLayouts() throws {
    let path = try addWorktree("wt", branch: "feat/layout")
    XCTAssertEqual(
      GitWorktreeOperationProbe.gitDir(worktreeAt: path),
      ((repo.commonDir as NSString).appendingPathComponent("worktrees/wt") as NSString)
        .standardizingPath,
      "リンク worktree は `.git` ファイルの gitdir: 行が指す先")
    XCTAssertEqual(
      GitWorktreeOperationProbe.gitDir(worktreeAt: dir.path),
      (dir.path as NSString).appendingPathComponent(".git"),
      "本体 worktree は `.git` ディレクトリそのもの")
    XCTAssertEqual(
      GitWorktreeOperationProbe.detect(worktreeAt: dir.appendingPathComponent("nowhere").path),
      .unknown, "読めなければ「判定できなかった」")
  }

  // MARK: - ヘルパ

  @discardableResult
  private func git(_ args: [String]) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: dir.path)
  }

  @discardableResult
  private func gitIn(_ cwd: String, _ args: [String]) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: cwd)
  }

  private func write(_ cwd: String, _ name: String, _ text: String) throws {
    try text.write(
      toFile: (cwd as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  private func addWorktree(_ name: String, branch: String) throws -> String {
    let path = dir.appendingPathComponent(name).path
    XCTAssertTrue(git(["worktree", "add", "-q", path, "-b", branch]).isSuccess)
    return path
  }

  /// 同じファイルを両側で書き換えて、rebase / merge が必ずコンフリクトする形を作る。
  private func makeDivergingCommits(at path: String) throws {
    try write(path, "a.txt", "theirs")
    XCTAssertTrue(gitIn(path, ["add", "-A"]).isSuccess)
    XCTAssertTrue(gitIn(path, ["commit", "-qm", "theirs"]).isSuccess)
    try write(dir.path, "a.txt", "ours")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "ours"]).isSuccess)
  }

  private func statusCounts(_ path: String) throws -> GitWorktreeStatusCounts? {
    var counts: GitWorktreeStatusCounts?
    let done = expectation(description: "worktreeStatusCounts")
    repo.worktreeStatusCounts(at: path) {
      counts = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return counts
  }

  private func open() throws -> GitRepo {
    var opened: GitRepo?
    let done = expectation(description: "GitRepo.open")
    GitRepo.open(cwd: dir.path) {
      opened = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return try XCTUnwrap(opened)
  }
}
