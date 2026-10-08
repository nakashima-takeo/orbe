import OrbeTestSupport
import XCTest

@testable import Orbe

/// 巻き添えが無いことの検証。git は並ばずに走り、順番が付くのは同じ worktree の index への根のサービスの書き込みだけ。
/// hook（ユーザーのコード＝所要時間に上限が無い）で止まった git が、その外の git を止めない。
///
/// ここが壊れると、1 本の返らない hook で worktree の掃除もワークスペース作成も別リポジトリのステージも返らなくなる
/// ——UI が丸ごと固まったように見え、ユーザーには原因が一切見えない。
@MainActor
final class GitCollateralTests: OrbeTestCase {
  private var fixture: GitHangFixture!
  private var repo: GitRepo!
  /// 止めた書き込みを投げたか／返ったか（どちらも main でのみ触る）。
  private var hangStarted = false
  private var hangReturned = false

  override func setUpWithError() throws {
    fixture = try GitHangFixture()
    repo = try open(fixture.root)
    // 失敗経路でも必ず解放する（解放し損ねると止まった git が後続のテストまで残る）。
    addTeardownBlock { @MainActor [self] in
      fixture.release()
      if hangStarted {
        pumpMain(until: { self.hangReturned }, timeout: 60, "解放した hook の git が返る")
      }
    }
  }

  // MARK: - ヘルパ

  private func open(_ cwd: String) throws -> GitRepo {
    var opened: GitRepo?
    let done = expectation(description: "GitRepo.open")
    GitRepo.open(cwd: cwd) {
      opened = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return try XCTUnwrap(opened)
  }

  private var root: String { GitWorktreeRoot.normalizedPath(fixture.root) }

  /// 根のサービスで、pre-commit hook の中で止まるコミットを投げ、**実際に hook へ入るまで**待つ。
  /// 「本当に止まっている」状態から測らないと、後続が通ったのは単にまだ始まっていないからかもしれない。
  private func startHangingCommit(_ files: RootFiles) throws {
    try fixture.installHook("pre-commit", body: fixture.waitingBody)
    try "changed\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    XCTAssertTrue(fixture.git(["add", "a.txt"]).isSuccess)
    hangStarted = true
    files.commit(message: "blocked") { [self] _ in hangReturned = true }
    XCTAssertTrue(fixture.pumpUntilHung(), "前提: pre-commit hook がハングしていること")
  }

  private func managed(_ root: String) -> RootFiles {
    let files = RootFiles(root: root)
    pumpMain(until: { files.status != nil }, "status の初回取得")
    return files
  }

  private func finish(
    _ start: (@escaping (GitWriteFailure?) -> Void) -> Void, timeout: TimeInterval = 5,
    _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) -> GitWriteFailure? {
    let outcome = WriteOutcome()
    start(outcome.receive)
    pumpMain(until: { outcome.finished }, timeout: timeout, message, file: file, line: line)
    return outcome.failure
  }

  // MARK: - 検証

  /// ハング中の worktree 作成は、同じリポジトリの書き込み（ブランチ削除）を止めない。
  /// 止めると、worktree の掃除が押しても何も起きない状態になる。
  func testHangingWorktreeAddDoesNotBlockOtherWrites() throws {
    XCTAssertTrue(fixture.git(["branch", "scratch"]).isSuccess)
    let oid = fixture.git(["rev-parse", "scratch"]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try fixture.installHook("post-checkout", body: fixture.waitingBody)
    hangStarted = true
    repo.addWorktree(
      path: fixture.worktreePath, base: "main",
      newBranch: GitNewBranch(name: "hang", tracksBase: false)
    ) { [self] _ in hangReturned = true }
    XCTAssertTrue(fixture.pumpUntilHung(), "前提: post-checkout hook がハングしていること")

    let done = expectation(description: "deleteBranch")
    repo.deleteBranch(name: "scratch", expectedOid: oid) { failure in
      // worktree 作成が触る ref（`refs/heads/hang`）と削除対象は交わらないので、巻き添えが無ければ必ず成功する。
      XCTAssertNil(failure, "ハング中でもブランチ削除は成功する")
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
  }

  /// ある worktree のコミットが hook で止まっている間も、その外の git は待たずに終わる——同じリポジトリの別の worktree・
  /// 別のリポジトリへの書き込み、worktree パレットの操作、あらゆる読み取りと観測。
  func testAHangingCommitBlocksNothingOutsideItsWorktree() throws {
    let linkedPath = fixture.dir.appendingPathComponent("linked").path
    XCTAssertTrue(fixture.git(["worktree", "add", "-q", "-b", "linked", linkedPath]).isSuccess)
    XCTAssertTrue(fixture.git(["branch", "scratch"]).isSuccess)
    let scratch = fixture.git(["rev-parse", "scratch"]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let other = try TempGitRepo()
    let files = managed(root)
    let linked = managed(GitWorktreeRoot.normalizedPath(linkedPath))
    let elsewhere = managed(other.root)
    try startHangingCommit(files)

    try "l\n".write(toFile: linkedPath + "/l.txt", atomically: true, encoding: .utf8)
    XCTAssertNil(
      finish(
        { linked.stage([GitStatus.Row(path: "l.txt", originalPath: nil)], completion: $0) },
        "同じリポジトリの別の worktree へのステージ"))
    XCTAssertEqual(linked.status?.entries["l.txt"]?.staged, .added)

    try other.write("o.txt", "o\n")
    XCTAssertNil(
      finish(
        { elsewhere.stage([GitStatus.Row(path: "o.txt", originalPath: nil)], completion: $0) },
        "別のリポジトリへのステージ"))

    XCTAssertNil(
      finish(
        { done in
          repo.deleteBranch(name: "scratch", expectedOid: scratch) {
            done($0.map { .reason($0.log) })
          }
        }, "worktree パレットのブランチ削除"))

    let observed = expectation(description: "観測と読み取り")
    observed.expectedFulfillmentCount = 4
    repo.status { status in
      XCTAssertEqual(status?.entries["a.txt"]?.staged, .modified)
      observed.fulfill()
    }
    repo.indexEntries(relativePaths: ["a.txt"]) { entries in
      XCTAssertNotNil(entries?["a.txt"])
      observed.fulfill()
    }
    repo.version(of: "a.txt", at: .head) { version in
      XCTAssertEqual(version, .present(Data("x\n".utf8)))
      observed.fulfill()
    }
    repo.commitGraph(limit: 10) { graph in
      XCTAssertEqual(graph?.commits.count, 1)
      observed.fulfill()
    }
    wait(for: [observed], timeout: 5)
  }

  /// 同じ worktree への書き込みは投げた順に 1 つずつ走る——止まったコミットの後ろのステージは、コミットが終わるまで
  /// 走らず（コミットに混ざらない）、終われば走る。
  func testWritesToOneWorktreeRunOneAtATimeInOrder() throws {
    let files = managed(root)
    try startHangingCommit(files)
    try "b\n".write(toFile: root + "/b.txt", atomically: true, encoding: .utf8)
    var order: [String] = []
    files.stage([GitStatus.Row(path: "b.txt", originalPath: nil)]) { failure in
      XCTAssertNil(failure)
      order.append("stage")
    }
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    XCTAssertEqual(
      fixture.git(["diff", "--cached", "--name-only"]).stdoutText, "a.txt\n",
      "止まったコミットの間、後ろのステージは走らない")

    fixture.release()
    pumpMain(until: { self.hangReturned && order == ["stage"] }, timeout: 20, "順に終わる")
    XCTAssertEqual(
      fixture.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "a.txt\n",
      "ステージはコミットに混ざらない")
    XCTAssertEqual(fixture.git(["diff", "--cached", "--name-only"]).stdoutText, "b.txt\n")
  }
}
