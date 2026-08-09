import XCTest

@testable import Orbe

/// 実 git 層: 一時リポジトリで「取り込み済み判定」「作業ツリーの clean 判定」「worktree の削除」を確かめる。
///
/// 中心は **素の `git cherry` では multi-commit squash を検出できない**という実測で、
/// 2 段構え（素の cherry → 累積差分のダングリングコミット → 再度 cherry）が要ることを固定する。
final class GitWorktreeCleanIntegrationTests: OrbeTestCase {
  private var dir: URL!
  private var repo: GitRepo!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-clean-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    XCTAssertTrue(git(["init", "-q", "-b", "main"]).isSuccess)
    XCTAssertTrue(git(["config", "user.email", "t@example.com"]).isSuccess)
    XCTAssertTrue(git(["config", "user.name", "t"]).isSuccess)
    try write("a.txt", "x")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "init"]).isSuccess)
    repo = try open()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  // MARK: - 取り込み済み判定

  /// **完了条件の直接の証拠**。2 コミットを squash マージしたブランチについて、
  /// `git branch --merged` は返さず・`rev-list --count` は 2・**素の `git cherry` も `+` を 2 本**返すのに、
  /// 2 段構えの判定は「取り込み済み」を返す。
  func testSquashMergedBranchIsDetectedAsMerged() throws {
    try makeSquashMergedBranch()

    XCTAssertFalse(
      git(["branch", "--merged", "main"]).stdoutText.contains("feat/squash"),
      "前提: 到達性では取り込み済みに見えない")
    XCTAssertEqual(
      git(["rev-list", "--count", "main..feat/squash"]).stdoutText
        .trimmingCharacters(in: .whitespacesAndNewlines), "2",
      "前提: main から見て 2 コミット未取り込みに見える")
    XCTAssertEqual(
      git(["cherry", "main", "feat/squash"]).stdoutText.split(separator: "\n")
        .filter { $0.hasPrefix("+") }.count, 2,
      "前提: 素の cherry は畳んだ patch-id を照合できず 2 本とも未取り込みと誤判定する")

    XCTAssertEqual(try unmerged("feat/squash"), 0, "2 段構えなら取り込み済みと判定できる")
  }

  /// 本当に未マージのブランチは独自コミット件数を返す（safe 群に入れない）。
  func testUnmergedBranchReportsOwnCommitCount() throws {
    try makeSquashMergedBranch()
    XCTAssertTrue(git(["checkout", "-q", "-b", "feat/live", "main"]).isSuccess)
    try write("d.txt", "1")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "u1"]).isSuccess)
    try write("d.txt", "12")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "u2"]).isSuccess)
    XCTAssertTrue(git(["checkout", "-q", "main"]).isSuccess)

    XCTAssertEqual(try unmerged("feat/live"), 2)
  }

  /// 既定ブランチの厳密な祖先（＝完全に取り込み済み）で偽陽性を出さない。
  /// 累積差分のレシピ**単独**では空パッチのダングリングコミットになり `+` を返してしまうため、
  /// 素の cherry を先に置く順序がここで効いている。
  func testAncestorBranchIsMerged() throws {
    let initial = git(["rev-parse", "HEAD"]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try makeSquashMergedBranch()
    XCTAssertTrue(git(["branch", "feat/ancestor", initial]).isSuccess)

    XCTAssertEqual(try unmerged("feat/ancestor"), 0)
  }

  // MARK: - 作業ツリーの clean 判定

  func testWorktreeIsCleanReflectsUncommittedChanges() throws {
    let path = dir.appendingPathComponent("wt").path
    XCTAssertTrue(git(["worktree", "add", "-q", path, "-b", "feat/wt"]).isSuccess)
    XCTAssertTrue(try isClean(path), "作った直後は clean")

    try "dirty".write(
      toFile: (path as NSString).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    XCTAssertFalse(try isClean(path), "未コミット変更があれば clean ではない")
  }

  /// **ユーザー設定で clean 判定を無力化できない**。`status.showUntrackedFiles=no` は巨大リポジトリの
  /// 高速化として広く使われるが、これが効くと未追跡ファイルだけの worktree が空出力＝clean に見え、
  /// `--force` 削除でそのファイルが復旧不能に消える。引数で明示して事実を固定していることを固定する。
  func testWorktreeIsCleanIgnoresShowUntrackedFilesSetting() throws {
    let path = dir.appendingPathComponent("wt").path
    XCTAssertTrue(git(["worktree", "add", "-q", path, "-b", "feat/wt"]).isSuccess)
    XCTAssertTrue(
      GitRunner.shared.runSync(["config", "status.showUntrackedFiles", "no"], cwd: path).isSuccess)
    try "note".write(
      toFile: (path as NSString).appendingPathComponent("memo.txt"), atomically: true,
      encoding: .utf8)

    XCTAssertTrue(
      GitRunner.shared.runSync(["status", "--porcelain"], cwd: path).stdoutText.isEmpty,
      "前提: 設定どおりなら素の status は未追跡ファイルを出さない")
    XCTAssertFalse(try isClean(path), "設定に関わらず未追跡ファイルは dirty と出る")
  }

  /// **git が失敗したら「確認できなかった」＝clean でない側に倒す**（0 と nil、true と false を混ぜない）。
  func testUnknownStateFallsToUnsafeSide() throws {
    XCTAssertFalse(
      try isClean(dir.appendingPathComponent("nowhere").path), "存在しないパスは clean と名乗らない")
    XCTAssertNil(try unmerged("no-such-branch"), "判定できなければ nil（取り込み済みの 0 とは別）")
  }

  // MARK: - 削除

  func testRemoveWorktreeDropsAdministrativeDirectory() throws {
    let path = dir.appendingPathComponent("wt").path
    XCTAssertTrue(git(["worktree", "add", "-q", path, "-b", "feat/wt"]).isSuccess)
    let admin = (repo.commonDir as NSString).appendingPathComponent("worktrees/wt")
    XCTAssertTrue(FileManager.default.fileExists(atPath: admin), "前提: 管理ディレクトリがある")

    XCTAssertNil(try remove(path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: admin), "管理ディレクトリごと消える")
  }

  /// **`--force` の根拠**。submodule を初期化した worktree は、作業ツリーが完全に clean でも
  /// 素の `git worktree remove` に拒否される。Orbe 自身のリポジトリも submodule を持つため、
  /// clean と unlocked を直前に検証したうえで `--force` を呼ぶのが唯一の道になる。
  func testSubmoduleWorktreeNeedsForce() throws {
    try addSubmodule()
    let path = dir.appendingPathComponent("wt").path
    XCTAssertTrue(git(["worktree", "add", "-q", path, "-b", "feat/wt"]).isSuccess)
    XCTAssertTrue(
      GitRunner.shared.runSync(
        ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q", "sub"],
        cwd: path
      ).isSuccess, "前提: worktree 側で submodule を初期化する")
    XCTAssertTrue(try isClean(path), "前提: 作業ツリーは clean")

    XCTAssertFalse(
      git(["worktree", "remove", path]).isSuccess, "clean でも素の remove は submodule を理由に拒否する")
    XCTAssertNil(try remove(path), "--force なら消える")
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }

  func testDeleteBranchRemovesUnmergedBranch() throws {
    XCTAssertTrue(git(["checkout", "-q", "-b", "feat/gone"]).isSuccess)
    try write("b.txt", "1")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "c1"]).isSuccess)
    XCTAssertTrue(git(["checkout", "-q", "main"]).isSuccess)
    let tip = git(["rev-parse", "feat/gone"]).stdoutText.trimmingCharacters(
      in: .whitespacesAndNewlines)

    XCTAssertNil(try deleteBranch("feat/gone", expecting: tip))
    XCTAssertFalse(git(["branch"]).stdoutText.contains("feat/gone"), "未取り込みでも到達性を問わず消える")
  }

  /// **凍結した判定でコミットを消さない**。分類してから削除するまでにブランチが進んだら、
  /// 先端が一致しないので削除は拒否される（worktree 側の dirty 再確認に対応する、ブランチ側の関門）。
  func testDeleteBranchRefusesWhenBranchMovedSinceProbe() throws {
    XCTAssertTrue(git(["checkout", "-q", "-b", "feat/moved"]).isSuccess)
    try write("b.txt", "1")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "c1"]).isSuccess)
    let probed = git(["rev-parse", "HEAD"]).stdoutText.trimmingCharacters(
      in: .whitespacesAndNewlines)
    // 分類の後にコミットが載る（別のペイン・別のツールから）。
    try write("c.txt", "1")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "c2"]).isSuccess)
    XCTAssertTrue(git(["checkout", "-q", "main"]).isSuccess)

    XCTAssertNotNil(try deleteBranch("feat/moved", expecting: probed), "先端が動いていたら消さない")
    XCTAssertTrue(git(["branch"]).stdoutText.contains("feat/moved"), "ブランチは残る")
  }

  // MARK: - ヘルパ

  @discardableResult
  private func git(_ args: [String]) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: dir.path)
  }

  private func write(_ name: String, _ text: String) throws {
    try text.write(
      toFile: (dir.path as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8
    )
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

  /// main に 2 コミットのブランチを squash マージした状態を作る。
  private func makeSquashMergedBranch() throws {
    XCTAssertTrue(git(["checkout", "-q", "-b", "feat/squash"]).isSuccess)
    try write("b.txt", "1")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "c1"]).isSuccess)
    try write("b.txt", "12")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "c2"]).isSuccess)
    XCTAssertTrue(git(["checkout", "-q", "main"]).isSuccess)
    XCTAssertTrue(git(["merge", "--squash", "feat/squash"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "squash"]).isSuccess)
  }

  /// ローカルの別リポジトリを submodule として取り込む（`file://` は既定で禁止なので明示的に許す）。
  private func addSubmodule() throws {
    let sub = dir.appendingPathComponent("subrepo")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let subGit = { (args: [String]) in GitRunner.shared.runSync(args, cwd: sub.path) }
    XCTAssertTrue(subGit(["init", "-q", "-b", "main"]).isSuccess)
    XCTAssertTrue(subGit(["config", "user.email", "t@example.com"]).isSuccess)
    XCTAssertTrue(subGit(["config", "user.name", "t"]).isSuccess)
    try "s".write(
      toFile: (sub.path as NSString).appendingPathComponent("s.txt"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(subGit(["add", "-A"]).isSuccess)
    XCTAssertTrue(subGit(["commit", "-qm", "sub"]).isSuccess)

    XCTAssertTrue(
      git([
        "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub.path, "sub",
      ]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "add submodule"]).isSuccess)
  }

  private func deleteBranch(_ name: String, expecting oid: String) throws -> String? {
    var error: String?
    let done = expectation(description: "deleteBranch")
    repo.deleteBranch(name: name, expectedOid: oid) {
      error = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return error
  }

  private func unmerged(_ branch: String) throws -> Int? {
    var value: Int?
    let done = expectation(description: "unmergedCommitCount")
    repo.unmergedCommitCount(branchOrCommit: branch, default: "main") {
      value = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return value
  }

  private func isClean(_ path: String) throws -> Bool {
    var value = false
    let done = expectation(description: "worktreeIsClean")
    repo.worktreeIsClean(at: path) {
      value = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return value
  }

  private func remove(_ path: String) throws -> String? {
    var error: String?
    let done = expectation(description: "removeWorktree")
    repo.removeWorktree(path: path) {
      error = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return error
  }
}
