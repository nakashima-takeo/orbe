import XCTest

@testable import Orbe

/// 削除の実行体を実 git で駆動する。**このコードベースで唯一の不可逆処理**なので、
/// 「止めるべきものを止める」側と「頼まれた残りを止めない」側の両方を固定する。
final class DispatchWorktreeCleanerTests: OrbeTestCase {
  private var dir: URL!
  private var repo: GitRepo!
  private var cleaner: DispatchWorktreeCleaner!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-cleaner-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    XCTAssertTrue(git(["init", "-q", "-b", "main"]).isSuccess)
    XCTAssertTrue(git(["config", "user.email", "t@example.com"]).isSuccess)
    XCTAssertTrue(git(["config", "user.name", "t"]).isSuccess)
    try write("a.txt", "x")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "init"]).isSuccess)
    repo = try open()
    cleaner = DispatchWorktreeCleaner(
      repo: repo, localization: LocalizationStore(language: .ja), prunablePaths: [])
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  /// **削除の直前に status をもう一度叩く。** 分類の後に汚れた worktree は消さず、
  /// それでも中断せず残りは消す（削除は取り消せないので、頼まれた残りを止める理由がない）。
  func testDirtyWorktreeIsSkippedAndTheRestStillRuns() throws {
    let dirty = try addWorktree("wt-dirty", branch: "feat/dirty")
    let clean = try addWorktree("wt-clean", branch: "feat/clean")
    try FileManager.default.removeItem(
      atPath: (dirty.path as NSString).appendingPathComponent("a.txt"))

    let result = try run([dirty.request(deleteBranch: false), clean.request(deleteBranch: false)])

    XCTAssertEqual(result.succeededPaths, [clean.path], "clean な方だけ消える")
    XCTAssertTrue(FileManager.default.fileExists(atPath: dirty.path), "dirty な方は残る")
    XCTAssertFalse(FileManager.default.fileExists(atPath: clean.path))
    XCTAssertNotNil(result.failureMessage, "失敗は握り潰さず集約する")
  }

  /// `deleteBranch` が false ならブランチは残る（判断は呼び出し側が持ち、実行体は従うだけ）。
  func testBranchSurvivesWhenNotRequested() throws {
    let wt = try addWorktree("wt", branch: "feat/keep")

    let result = try run([wt.request(deleteBranch: false)])

    XCTAssertEqual(result.succeededPaths, [wt.path])
    XCTAssertNil(result.failureMessage)
    XCTAssertTrue(git(["branch"]).stdoutText.contains("feat/keep"), "頼まれていないブランチは消さない")
  }

  func testBranchIsDeletedWhenRequested() throws {
    let wt = try addWorktree("wt", branch: "feat/drop")

    let result = try run([wt.request(deleteBranch: true)])

    XCTAssertEqual(result.succeededPaths, [wt.path])
    XCTAssertNil(result.failureMessage)
    XCTAssertFalse(git(["branch"]).stdoutText.contains("feat/drop"))
  }

  /// 分類してから実行するまでにブランチが進んだら、worktree は消えてもブランチは残る
  /// （凍結した判定でコミットを消さない）。
  func testBranchSurvivesWhenItMovedSinceClassification() throws {
    let wt = try addWorktree("wt", branch: "feat/moved")
    // 分類の後に別の経路からコミットが載る。
    try write("b.txt", "1", in: wt.path)
    XCTAssertTrue(gitIn(wt.path, ["add", "-A"]).isSuccess)
    XCTAssertTrue(gitIn(wt.path, ["commit", "-qm", "later"]).isSuccess)

    let result = try run([wt.request(deleteBranch: true)])

    XCTAssertEqual(result.succeededPaths, [wt.path], "worktree（作業コピー）は消える")
    XCTAssertTrue(git(["branch"]).stdoutText.contains("feat/moved"), "コミットごと消えない")
    XCTAssertNotNil(result.failureMessage)
  }

  // MARK: - ヘルパ

  private struct Worktree {
    let path: String
    let branch: String
    let head: String
    func request(deleteBranch: Bool) -> CleanDeleteRequest {
      CleanDeleteRequest(path: path, branch: branch, head: head, deleteBranch: deleteBranch)
    }
  }

  private func addWorktree(_ name: String, branch: String) throws -> Worktree {
    let path = dir.appendingPathComponent(name).path
    XCTAssertTrue(git(["worktree", "add", "-q", path, "-b", branch]).isSuccess)
    let head = git(["rev-parse", branch]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Worktree(path: path, branch: branch, head: head)
  }

  private func run(_ requests: [CleanDeleteRequest]) throws -> CleanDeleteResult {
    var value: CleanDeleteResult?
    let done = expectation(description: "cleaner.run")
    cleaner.run(requests) {
      value = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    return try XCTUnwrap(value)
  }

  @discardableResult
  private func git(_ args: [String]) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: dir.path)
  }

  @discardableResult
  private func gitIn(_ cwd: String, _ args: [String]) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: cwd)
  }

  private func write(_ name: String, _ text: String, in cwd: String? = nil) throws {
    try text.write(
      toFile: ((cwd ?? dir.path) as NSString).appendingPathComponent(name), atomically: true,
      encoding: .utf8)
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
