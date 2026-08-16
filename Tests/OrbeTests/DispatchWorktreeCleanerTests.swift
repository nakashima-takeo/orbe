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

    let outcomes = try run([dirty.request(deleteBranch: false), clean.request(deleteBranch: false)])

    XCTAssertEqual(outcomes[dirty.path], .failed(CleanFailure(step: .dirty, log: "")))
    XCTAssertEqual(outcomes[clean.path], .succeeded(branch: nil, pruned: false))
    XCTAssertTrue(FileManager.default.fileExists(atPath: dirty.path), "dirty な方は残る")
    XCTAssertFalse(FileManager.default.fileExists(atPath: clean.path))
  }

  /// `deleteBranch` が false ならブランチは残る（判断は呼び出し側が持ち、実行体は従うだけ）。
  func testBranchSurvivesWhenNotRequested() throws {
    let wt = try addWorktree("wt", branch: "feat/keep")

    let outcomes = try run([wt.request(deleteBranch: false)])

    XCTAssertEqual(outcomes[wt.path], .succeeded(branch: nil, pruned: false))
    XCTAssertTrue(git(["branch"]).stdoutText.contains("feat/keep"), "頼まれていないブランチは消さない")
  }

  func testBranchIsDeletedWhenRequested() throws {
    let wt = try addWorktree("wt", branch: "feat/drop")

    let outcomes = try run([wt.request(deleteBranch: true)])

    XCTAssertEqual(
      outcomes[wt.path], .succeeded(branch: "feat/drop", pruned: false),
      "成功はブランチ名まで名乗る（行のメッセージがそこから出る）")
    XCTAssertFalse(git(["branch"]).stdoutText.contains("feat/drop"))
  }

  /// 分類してから実行するまでにブランチが進んだら、worktree は消えてもブランチは残る
  /// （確定した時点の判定でコミットを消さない）。失敗は per-row で返り、**生ログが載る**。
  func testBranchSurvivesWhenItMovedSinceClassification() throws {
    let wt = try addWorktree("wt", branch: "feat/moved")
    // 分類の後に別の経路からコミットが載る。
    try write("b.txt", "1", in: wt.path)
    XCTAssertTrue(gitIn(wt.path, ["add", "-A"]).isSuccess)
    XCTAssertTrue(gitIn(wt.path, ["commit", "-qm", "later"]).isSuccess)

    let outcomes = try run([wt.request(deleteBranch: true)])

    XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path), "worktree（作業コピー）は消える")
    XCTAssertTrue(git(["branch"]).stdoutText.contains("feat/moved"), "コミットごと消えない")
    guard case .failed(let failure) = try XCTUnwrap(outcomes[wt.path]) else {
      return XCTFail("失敗として返るべき")
    }
    XCTAssertEqual(failure.step, .branch)
    XCTAssertFalse(failure.log.isEmpty, "サブラインへ出す git の生ログが載る")
    XCTAssertFalse(failure.log.contains("\n"), "1 行に畳んである")
  }

  /// **停止中の git 操作も削除の直前に確かめる。** status は空でも rebase 途中の worktree は消さない
  /// （分類が safe に入れる条件と、撃つ直前に確かめる条件を食い違わせない）。
  func testWorktreeWithAStoppedRebaseIsNotDeleted() throws {
    let wt = try addWorktree("wt-rebase", branch: "feat/rebase")
    // gitdir 直下に停止中 rebase の管理ディレクトリだけを置く（status は空のまま）。
    let gitDir = try XCTUnwrap(GitWorktreeOperationProbe.gitDir(worktreeAt: wt.path))
    try FileManager.default.createDirectory(
      atPath: (gitDir as NSString).appendingPathComponent("rebase-merge"),
      withIntermediateDirectories: true)
    XCTAssertTrue(gitIn(wt.path, ["status", "--porcelain"]).stdoutText.isEmpty, "status は clean")

    let outcomes = try run([wt.request(deleteBranch: true)])

    XCTAssertEqual(
      outcomes[wt.path], .failed(CleanFailure(step: .operationInProgress, log: "")),
      "撃つ前に止めるので git の生ログは無い")
    XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))
    XCTAssertTrue(git(["branch"]).stdoutText.contains("feat/rebase"), "ブランチにも触らない")
  }

  /// 実体の消えた worktree（prunable）は status のゲートを省いて登録だけを掃除する。
  /// **省かないと必ず失敗する**——実体の無いパスへの status は起動できず「clean でない」に倒れる。
  func testPrunableWorktreeSkipsTheStatusGate() throws {
    let wt = try addWorktree("wt-gone", branch: "feat/gone")
    try FileManager.default.removeItem(atPath: wt.path)
    cleaner = DispatchWorktreeCleaner(
      repo: repo, localization: LocalizationStore(language: .ja), prunablePaths: [wt.path])

    let outcomes = try run([wt.request(deleteBranch: false)])

    XCTAssertEqual(outcomes[wt.path], .succeeded(branch: nil, pruned: true))
    XCTAssertFalse(git(["worktree", "list"]).stdoutText.contains(wt.path), "登録が残らない")
  }

  /// ブランチ削除だけが落ちた行の再試行は、**worktree のステップを飛ばしてブランチ削除から撃つ**。
  /// 飛ばさないと、実体の無いパスへの status で必ず落ち「未コミットの変更がある」と逆の理由が出る。
  func testRetryOfABranchFailureDeletesTheBranchAlone() throws {
    let wt = try addWorktree("wt", branch: "feat/retry")
    XCTAssertTrue(git(["worktree", "remove", "--force", wt.path]).isSuccess)
    var request = wt.request(deleteBranch: true)
    request.worktreeAlreadyRemoved = true

    let outcomes = try run([request])

    XCTAssertEqual(outcomes[wt.path], .succeeded(branch: "feat/retry", pruned: false))
    XCTAssertFalse(git(["branch"]).stdoutText.contains("feat/retry"), "残っていたブランチが消える")
  }

  /// **中断は「まだ撃っていない残り」だけを止める。** 1 件目の実行中に札を立てたら 2 件目は撃たれない。
  func testCancelStopsTheRemainingRequests() throws {
    let first = try addWorktree("wt-1", branch: "feat/1")
    let second = try addWorktree("wt-2", branch: "feat/2")
    let token = CleanRunToken()

    var outcomes: [String: CleanOutcome] = [:]
    let done = expectation(description: "cleaner.run")
    cleaner.run(
      [first.request(deleteBranch: false), second.request(deleteBranch: false)], token: token
    ) { progress in
      switch progress {
      case .started: token.cancel()  // 1 件目が走り出した時点で中断する
      case .finished(let path, let outcome): outcomes[path] = outcome
      }
    } completion: {
      done.fulfill()
    }
    wait(for: [done], timeout: 30)

    XCTAssertEqual(outcomes[first.path], .succeeded(branch: nil, pruned: false), "撃った 1 件は完走する")
    XCTAssertNil(outcomes[second.path], "以降は撃たない")
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
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

  /// 1 件ごとの結果をパスで集める（実行体は per-row の結果しか返さない）。
  private func run(_ requests: [CleanDeleteRequest]) throws -> [String: CleanOutcome] {
    var outcomes: [String: CleanOutcome] = [:]
    let done = expectation(description: "cleaner.run")
    cleaner.run(requests, token: CleanRunToken()) { progress in
      if case .finished(let path, let outcome) = progress { outcomes[path] = outcome }
    } completion: {
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    return outcomes
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
