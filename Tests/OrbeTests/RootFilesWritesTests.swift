import OrbeTestSupport
import XCTest

@testable import Orbe

/// 根のサービスの書き込み（実 git）: ステージ・解除・破棄・コミット・amend・取り消しが status をその通りに変え、完了が
/// 届いた時点で status がもう書き込み後の姿になっている。
///
/// 壊れると何が起きるか。ステージした行が「変更」に残る・rename を解除すると元パスの削除だけが index に残る・`*` を含む
/// 名前で別のファイルがステージされる・破棄でステージ済みの分まで消える・未追跡の破棄で取り返しがつかない・`#` の行が
/// メッセージから消える・取り消しで中身ごと失う・smudge が止まるとステージの完了が返らない。
@MainActor
final class RootFilesWritesTests: OrbeTestCase {
  var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  private func finish(
    _ files: RootFiles, _ start: (@escaping (GitWriteFailure?) -> Void) -> RootFiles.Write,
    file: StaticString = #filePath, line: UInt = #line
  ) -> WriteOutcome {
    let outcome = WriteOutcome(files)
    _ = start(outcome.receive)
    pumpMain(until: { outcome.finished }, timeout: 20, "書き込みの完了", file: file, line: line)
    return outcome
  }

  private func entry(_ outcome: WriteOutcome, _ path: String) -> GitStatus.Entry? {
    outcome.statusAtCompletion?.entries[path]
  }

  // MARK: - ステージ・解除

  /// 変更・削除・未追跡・rename（元パスごと）・`*` `:` を含む名前のどれでも、行に対する操作で status がその通りに変わる。
  /// 完了が届いた時点で status は書き込み後の姿（監視の到着を待たない）。
  func testStageAndUnstageFollowEveryKindOfRow() throws {
    try repo.write("gone.txt", "g\n")
    try repo.write("old.txt", "rename me\n")
    try repo.write("star*.txt", "s\n")
    try repo.write("star1.txt", "decoy\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "more"]).isSuccess)
    try repo.write("a.txt", "changed\n")
    try FileManager.default.removeItem(atPath: repo.root + "/gone.txt")
    try repo.write("new/inner.txt", "n\n")
    try repo.write(":colon.txt", "c\n")
    try FileManager.default.moveItem(
      atPath: repo.root + "/old.txt", toPath: repo.root + "/moved.txt")
    try repo.write("star*.txt", "s2\n")
    try repo.write("star1.txt", "decoy2\n")
    let files = repo.files()
    let rows = [
      "a.txt", "gone.txt", "new/inner.txt", ":colon.txt", "moved.txt", "old.txt", "star*.txt",
    ]
    .map { GitStatus.Row(path: $0, originalPath: nil) }

    let staged = finish(files) { files.stage(rows, completion: $0) }
    XCTAssertNil(staged.failure)
    XCTAssertEqual(entry(staged, "a.txt"), GitStatus.Entry(staged: .modified, unstaged: nil))
    XCTAssertEqual(entry(staged, "gone.txt"), GitStatus.Entry(staged: .deleted, unstaged: nil))
    XCTAssertEqual(entry(staged, "new/inner.txt"), GitStatus.Entry(staged: .added, unstaged: nil))
    XCTAssertEqual(entry(staged, ":colon.txt"), GitStatus.Entry(staged: .added, unstaged: nil))
    XCTAssertEqual(
      entry(staged, "moved.txt"),
      GitStatus.Entry(staged: .renamed, unstaged: nil, originalPath: "old.txt"))
    XCTAssertEqual(entry(staged, "star*.txt"), GitStatus.Entry(staged: .modified, unstaged: nil))
    XCTAssertEqual(
      entry(staged, "star1.txt"), GitStatus.Entry(staged: nil, unstaged: .modified),
      "名前は glob にならない")

    let status = try XCTUnwrap(files.status)
    let unstaged = finish(files) {
      files.unstage(
        ["a.txt", "gone.txt", "moved.txt", ":colon.txt"].map(status.row), completion: $0)
    }
    XCTAssertNil(unstaged.failure)
    XCTAssertEqual(entry(unstaged, "a.txt"), GitStatus.Entry(staged: nil, unstaged: .modified))
    XCTAssertEqual(entry(unstaged, "gone.txt"), GitStatus.Entry(staged: nil, unstaged: .deleted))
    XCTAssertEqual(
      entry(unstaged, ":colon.txt"), GitStatus.Entry(staged: nil, unstaged: .untracked))
    XCTAssertEqual(
      entry(unstaged, "moved.txt"), GitStatus.Entry(staged: nil, unstaged: .untracked),
      "rename の行の解除は元パスの削除の側も解く")
    XCTAssertEqual(
      entry(unstaged, "old.txt"), GitStatus.Entry(staged: nil, unstaged: .deleted),
      "元パスは index に戻り、作業ツリーで消えた形になる")
    XCTAssertEqual(entry(unstaged, "new/inner.txt")?.staged, .added, "選ばなかった行は動かない")
  }

  /// 初回コミット前のリポジトリでもステージと解除が効く（`restore --staged` は HEAD が無いと落ちる）。
  func testStageAndUnstageWorkBeforeTheFirstCommit() throws {
    let fresh = try TempGitRepo(initialCommit: false)
    try fresh.write("first.txt", "f\n")
    let files = fresh.files()
    let row = GitStatus.Row(path: "first.txt", originalPath: nil)

    let staged = finish(files) { files.stage([row], completion: $0) }
    XCTAssertNil(staged.failure)
    XCTAssertEqual(staged.statusAtCompletion?.entries["first.txt"]?.staged, .added)

    let unstaged = finish(files) { files.unstage([row], completion: $0) }
    XCTAssertNil(unstaged.failure)
    XCTAssertEqual(unstaged.statusAtCompletion?.entries["first.txt"]?.unstaged, .untracked)
  }

  // MARK: - 破棄

  /// 追跡中のファイルの破棄は作業ツリーを index の版へ戻し、ステージ済みの分は残す。
  func testDiscardRestoresTheIndexVersionAndKeepsWhatIsStaged() throws {
    try repo.write("a.txt", "staged\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    try repo.write("a.txt", "staged then edited\n")
    let files = repo.files()

    let discarded = finish(files) { files.discard([files.status!.row("a.txt")], completion: $0) }
    XCTAssertNil(discarded.failure)
    XCTAssertEqual(entry(discarded, "a.txt"), GitStatus.Entry(staged: .modified, unstaged: nil))
    XCTAssertEqual(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8), "staged\n")
  }

  /// 未追跡ファイルの破棄はゴミ箱へ移す（元の場所から消え、ゴミ箱にある）。
  func testDiscardMovesAnUntrackedFileToTheTrash() throws {
    let name = "untracked-\(UUID().uuidString).txt"
    try repo.write(name, "keep me recoverable\n")
    let files = repo.files()
    let trash = try FileManager.default.url(
      for: .trashDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: repo.root),
      create: false)
    let trashed = trash.appendingPathComponent(name)
    defer { try? FileManager.default.removeItem(at: trashed) }

    let discarded = finish(files) { files.discard([files.status!.row(name)], completion: $0) }
    XCTAssertNil(discarded.failure)
    XCTAssertNil(entry(discarded, name))
    XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root + "/" + name), "元の場所から消える")
    XCTAssertEqual(
      try String(contentsOf: trashed, encoding: .utf8), "keep me recoverable\n", "ゴミ箱にある")
  }

  // MARK: - コミット・amend・取り消し

  /// ステージ済みの分だけがコミットされ、メッセージは `#` の行も含め書いたまま残る（前後の空行と行末の空白だけ落ちる）。
  func testCommitTakesOnlyTheStagedPartAndKeepsTheMessageAsWritten() throws {
    try repo.write("a.txt", "staged\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    try repo.write("b.txt", "not staged\n")
    let files = repo.files()

    let committed = finish(files) {
      files.commit(message: "\n\nTitle  \n\n# not a comment\nbody\n\n", completion: $0)
    }
    XCTAssertNil(committed.failure)
    XCTAssertEqual(
      repo.git(["log", "-1", "--format=%B"]).stdoutText, "Title\n\n# not a comment\nbody\n\n")
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "a.txt\n")
    XCTAssertNil(entry(committed, "a.txt"), "完了の時点で clean")
    XCTAssertEqual(entry(committed, "b.txt")?.unstaged, .untracked)
    XCTAssertEqual(committed.statusAtCompletion?.branch?.commit, repo.head())
  }

  /// 何もステージしていないコミットは、git が stdout に言った理由で失敗する。
  func testCommittingNothingFailsWithGitsReason() throws {
    let files = repo.files()
    let committed = finish(files) { files.commit(message: "empty", completion: $0) }
    guard case .reason(let reason) = committed.failure else {
      return XCTFail("理由つきの失敗: \(String(describing: committed.failure))")
    }
    XCTAssertTrue(reason.contains("nothing to commit"), reason)
  }

  /// amend はメッセージが空なら前のメッセージのまま中身だけ差し替え、あれば差し替える。
  func testAmendReplacesTheLastCommit() throws {
    let files = repo.files()
    let before = repo.head()
    try repo.write("a.txt", "amended\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)

    let kept = finish(files) { files.commit(message: "  \n", amend: true, completion: $0) }
    XCTAssertNil(kept.failure)
    XCTAssertNotEqual(repo.head(), before)
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "init\n")
    XCTAssertEqual(repo.git(["rev-list", "--count", "HEAD"]).stdoutText, "1\n", "積まずに差し替える")
    XCTAssertEqual(repo.git(["show", "HEAD:a.txt"]).stdoutText, "amended\n")

    let renamed = finish(files) { files.commit(message: "renamed", amend: true, completion: $0) }
    XCTAssertNil(renamed.failure)
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "renamed\n")
  }

  /// 取り消すと HEAD が 1 つ戻り、中身はステージ済みに残る。初回コミットの取り消しは初回コミット前にステージ済みで戻る。
  func testUndoingTheLastCommitKeepsItsContentStaged() throws {
    let first = repo.head()
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "b.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "second"]).isSuccess)
    let files = repo.files()

    let undone = finish(files) { files.undoLastCommit(completion: $0) }
    XCTAssertNil(undone.failure)
    XCTAssertEqual(repo.head(), first)
    XCTAssertEqual(entry(undone, "b.txt"), GitStatus.Entry(staged: .added, unstaged: nil))
    XCTAssertEqual(undone.statusAtCompletion?.branch?.commit, first)

    XCTAssertTrue(repo.git(["commit", "-qm", "second again"]).isSuccess)
    XCTAssertTrue(repo.git(["reset", "-q", "--hard", first]).isSuccess)
    let root = finish(files) { files.undoLastCommit(completion: $0) }
    XCTAssertNil(root.failure)
    XCTAssertEqual(
      root.statusAtCompletion?.branch, GitStatus.Branch(name: "main", commit: nil, upstream: nil),
      "初回コミット前に戻る")
    XCTAssertEqual(entry(root, "a.txt"), GitStatus.Entry(staged: .added, unstaged: nil))
  }

  /// ユーザーの hook（pre-commit）と署名の設定はそのまま効く。
  func testUserHooksAndSigningStillApply() throws {
    let key = TestScratch.caseDir.appendingPathComponent("signing-key").path
    let keygen = Process()
    keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", key]
    try keygen.run()
    keygen.waitUntilExit()
    XCTAssertEqual(keygen.terminationStatus, 0, "前提: 署名の鍵を作れる")
    for args in [
      ["config", "gpg.format", "ssh"], ["config", "user.signingkey", key],
      ["config", "commit.gpgsign", "true"],
    ] {
      XCTAssertTrue(repo.git(args).isSuccess)
    }
    let marker = repo.root + "/.git/pre-commit-ran"
    try repo.write(".git/hooks/pre-commit", "#!/bin/sh\n: > \"\(marker)\"\n")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: repo.root + "/.git/hooks/pre-commit")
    try repo.write("a.txt", "signed\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    let files = repo.files()

    let committed = finish(files) { files.commit(message: "signed", completion: $0) }
    XCTAssertNil(committed.failure)
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "pre-commit が走った")
    XCTAssertTrue(repo.git(["cat-file", "commit", "HEAD"]).stdoutText.contains("gpgsig"), "署名された")
  }

  // MARK: - 完了の時点

  /// 前の取り直しの baseline 取得（smudge）が止まっていても、書き込みの完了は遅れない。
  func testACompletionDoesNotWaitForAStuckBaseline() throws {
    let fixture = try GitHangFixture()
    let smudge = try fixture.installScript("smudge.sh", body: fixture.waitingBody)
    defer { fixture.release() }
    try repo.write(".gitattributes", "*.slow filter=slow\n")
    try repo.write("x.slow", "slow\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "slow"]).isSuccess)
    XCTAssertTrue(repo.git(["config", "filter.slow.smudge", smudge]).isSuccess)
    let files = repo.files()
    let watcher = RootFilesTests.Recorder()
    files.addObserver(watcher, interest: repo.url("x.slow"))
    XCTAssertTrue(fixture.pumpUntilHung(), "前提: baseline の smudge が止まっている")

    try repo.write("b.txt", "b\n")
    let started = Date()
    let staged = finish(files) {
      files.stage([GitStatus.Row(path: "b.txt", originalPath: nil)], completion: $0)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "smudge の後ろに並ばない")
    XCTAssertNil(staged.failure)
    XCTAssertEqual(entry(staged, "b.txt")?.staged, .added)
  }

  /// git 管理外の根では書き込めない。
  func testAnUnmanagedRootRefusesWrites() throws {
    let outside = TestScratch.caseDir.appendingPathComponent("plain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let files = RootFiles(root: GitWorktreeRoot.normalizedPath(outside.path))
    pumpMain(until: { files.isResolved })
    XCTAssertEqual(
      finish(files) { files.commit(message: "x", completion: $0) }.failure, .notManaged)
  }
}
