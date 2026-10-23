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

  /// 破棄は、各パスの行き先が押した時点に見えていたものと違えば何も書かずに断る——未追跡に見えていたファイルが外で
  /// `git add` されて編集されていても（監視が届く前）、確認なしに index の版へ戻して編集を消さない。逆向き（戻すと見えて
  /// いたものが外で `git rm --cached` された）も断る。見え方が追いつけば通る。
  func testDiscardRefusesWhenWhereAPathGoesDiffersFromWhatWasSeen() throws {
    try repo.write("new.txt", "first\n")
    try repo.write("a.txt", "edited\n")
    let files = repo.files()
    let seenNew = files.status!.discarding("new.txt")
    let seenA = files.status!.discarding("a.txt")
    XCTAssertEqual(seenNew.trashed, ["new.txt"], "前提: 未追跡に見えている")
    XCTAssertEqual(seenA.trashed, [], "前提: 戻すと見えている")
    XCTAssertTrue(repo.git(["add", "new.txt"]).isSuccess)
    try repo.write("new.txt", "first\nadded after git add\n")
    XCTAssertTrue(repo.git(["rm", "-q", "--cached", "a.txt"]).isSuccess)
    let index = repo.git(["ls-files", "-s"]).stdoutText

    for seen in [seenNew, seenA] {
      XCTAssertEqual(
        finish(files) { files.discard(seen, completion: $0) }.failure, .contentMismatch)
    }
    XCTAssertEqual(
      try String(contentsOfFile: repo.root + "/new.txt", encoding: .utf8),
      "first\nadded after git add\n")
    XCTAssertEqual(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8), "edited\n")
    XCTAssertEqual(repo.git(["ls-files", "-s"]).stdoutText, index, "index も変わらない")

    let caughtUp = finish(files) {
      files.discard(files.status!.discarding("new.txt", "a.txt"), completion: $0)
    }
    XCTAssertNil(caughtUp.failure)
    XCTAssertEqual(try String(contentsOfFile: repo.root + "/new.txt", encoding: .utf8), "first\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root + "/a.txt"), "ゴミ箱へ移る")
  }
}
