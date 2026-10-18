import OrbeTestSupport
import XCTest

@testable import Orbe

extension RootFilesWritesTests {
  /// コミットに入るパスが押した時点に見えていた行と違えば、コミットも amend も何も書かずに断る——外でステージされた・
  /// HEAD が戻って index との差が増えた・先にステージする行が消えた、のどれでも、先にステージする行もステージしない。
  func testCommitsRefuseWhenTheContentDiffersFromTheRowsAndWriteNothing() throws {
    let files = repo.files()
    try repo.write("a.txt", "seen\n")
    try repo.write("unseen.txt", "secret\n")
    try repo.write("n.txt", "new\n")
    XCTAssertTrue(repo.git(["add", "a.txt", "unseen.txt"]).isSuccess)
    assertRefused(
      files,
      [
        ("外でステージされた", .staged("a.txt")),
        ("ステージ済みが見えていない", .staging([.init(path: "n.txt", originalPath: nil)])),
      ])

    XCTAssertTrue(repo.git(["reset", "-q", "a.txt", "unseen.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["add", "n.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "n"]).isSuccess)
    XCTAssertTrue(repo.git(["reset", "-q", "--soft", "HEAD~1"]).isSuccess)
    assertRefused(files, [("HEAD が戻った", .staged())])

    XCTAssertTrue(repo.git(["reset", "-q"]).isSuccess)
    assertRefused(
      files,
      [
        (
          "先にステージする行が消えた",
          .staging(["n.txt", "gone.txt"].map { .init(path: $0, originalPath: nil) })
        )
      ])
  }

  /// 見えていたステージ済みは版で照らす——同じパスを外でステージし直すと、名前は変わらないが版の違いで断る。
  func testCommitsRefuseWhenAStagedPathWasRestagedOutside() throws {
    try repo.write("a.txt", "staged\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    try repo.write("a.txt", "working tree\n")
    let files = repo.files()
    let seen = GitCommitContent.seen(try XCTUnwrap(files.status))
    XCTAssertEqual(Array(seen.staged.keys), ["a.txt"], "前提: ステージ済みと変更の両方に出ている")

    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    assertRefused(files, [("作業ツリーの版を外でステージした", seen)])
  }

  /// 外でのコミットで HEAD が進むと、index も作業ツリーも見えていたままでも、コミット・amend・取り消しは何も書かずに断る
  /// ——見えていないコミットの上に重ねない・書き換えない・取り消さない。
  func testCommitsAndUndoRefuseWhenTheHeadMovedOutside() throws {
    try repo.write("a.txt", "edited\n")
    let files = repo.files()
    let seen = GitCommitContent.seen(try XCTUnwrap(files.status))
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "agent"]).isSuccess)
    assertRefused(files, [("外でのコミット", seen)])

    let head = repo.head()
    let undone = finish(files) { files.undoLastCommit(head: seen.head, completion: $0) }
    XCTAssertEqual(undone.failure, .contentMismatch)
    XCTAssertEqual(repo.head(), head, "外のコミットを取り消さない")
  }

  /// 初回コミット前のリポジトリでも、見えていたものでコミットできる（HEAD を照らす `rev-parse` は HEAD が無いと落ちる）。
  func testCommitWorksBeforeTheFirstCommit() throws {
    let fresh = try TempGitRepo(initialCommit: false)
    try fresh.write("first.txt", "f\n")
    let files = fresh.files()
    let seen = GitCommitContent.seen(try XCTUnwrap(files.status))

    let committed = finish(files) { files.commit(message: "first", content: seen, completion: $0) }
    XCTAssertNil(committed.failure)
    XCTAssertEqual(
      fresh.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "first.txt\n")
  }

  /// rename のステージ済みの行は、index と HEAD の差の両側（元パスと新しいパス）に当たるので、断らずにコミットできる。
  func testAStagedRenameIsCommittedAsItsRowShowsIt() throws {
    try repo.write("old.txt", "body\n")
    XCTAssertTrue(repo.git(["add", "old.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "old"]).isSuccess)
    XCTAssertTrue(repo.git(["mv", "old.txt", "moved.txt"]).isSuccess)
    let files = repo.files()
    let status = try XCTUnwrap(files.status)
    XCTAssertEqual(status.row("moved.txt").originalPath, "old.txt", "前提: rename の行")

    let committed = finish(files) {
      files.commit(message: "mv", content: .seen(status), completion: $0)
    }
    XCTAssertNil(committed.failure)
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, "")
  }

  private func assertRefused(
    _ files: RootFiles, _ cases: [(String, GitCommitContent)], line: UInt = #line
  ) {
    for (name, content) in cases {
      for amend in [false, true] {
        let (head, index) = (repo.head(), repo.git(["ls-files", "-s"]).stdoutText)
        let committed = finish(files) {
          files.commit(message: "m", content: content, amend: amend, completion: $0)
        }
        XCTAssertEqual(committed.failure, .contentMismatch, "\(name) amend: \(amend)", line: line)
        XCTAssertEqual(repo.head(), head, "\(name) amend: \(amend)", line: line)
        XCTAssertEqual(
          repo.git(["ls-files", "-s"]).stdoutText, index, "\(name) amend: \(amend): index は押す前のまま",
          line: line)
      }
    }
  }
}
