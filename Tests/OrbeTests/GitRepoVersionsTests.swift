import XCTest

@testable import Orbe

/// 版の本文（実 git）: あるパスの HEAD 版・index 版・任意のコミットの版を、作業ツリーに出したときの姿（smudge・eol を
/// 通す。baseline と同じ底）で取り、「その版に無い」と「git の失敗」を区別する。
///
/// 壊れると何が起きるか。diff の左が作業ツリーと違う改行で全行が差分になる・新規ファイルの diff が「読めなかった」になる・
/// filter の失敗が「無い」に見えて全行が追加になる。
final class GitRepoVersionsTests: OrbeTestCase {
  private var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  private func version(
    _ git: GitRepo, _ path: String, _ revision: GitRevision
  ) -> GitVersionText? {
    var result: GitVersionText?
    let done = expectation(description: "version")
    git.version(of: path, at: revision) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return result
  }

  private func text(_ value: String) -> GitVersionText { .present(Data(value.utf8)) }

  func testReadsHeadIndexAndCommitVersions() throws {
    let git = try repo.open()
    let first = repo.head()
    try repo.write("a.txt", "two\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "two"]).isSuccess)
    try repo.write("a.txt", "staged\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    try repo.write("a.txt", "worktree\n")
    try repo.write("odd:name.txt", "colon\n")
    XCTAssertTrue(repo.git(["add", "odd:name.txt"]).isSuccess)

    XCTAssertEqual(version(git, "a.txt", .head), text("two\n"))
    XCTAssertEqual(version(git, "a.txt", .index), text("staged\n"))
    XCTAssertEqual(version(git, "a.txt", .commit(first)), text("one\n"))
    XCTAssertEqual(version(git, "odd:name.txt", .index), text("colon\n"))
  }

  /// 姿は作業ツリーに出したときのもの——パスの属性で eol と smudge が掛かる。
  func testVersionsAreSmudgedAndEOLConvertedForTheirPath() throws {
    let git = try repo.open()
    try repo.write(".gitattributes", "*.crlf text eol=crlf\n*.up filter=up\n")
    XCTAssertTrue(repo.git(["config", "filter.up.smudge", "tr a-z A-Z"]).isSuccess)
    try repo.write("b.crlf", "one\ntwo\n")
    try repo.write("c.up", "shout\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "attrs"]).isSuccess)

    XCTAssertEqual(version(git, "b.crlf", .head), text("one\r\ntwo\r\n"))
    XCTAssertEqual(version(git, "c.up", .index), text("SHOUT\n"))
  }

  /// 「その版に無い」（新規・削除・初回コミット前・ディレクトリ）と「git の失敗」（smudge の失敗）は区別される。
  func testAbsenceIsNotAFailure() throws {
    let git = try repo.open()
    try repo.write("new.txt", "n\n")
    XCTAssertEqual(version(git, "new.txt", .head), .absent)
    XCTAssertEqual(version(git, "new.txt", .index), .absent)
    try repo.write("dir/x.txt", "x\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "dir"]).isSuccess)
    XCTAssertEqual(version(git, "dir", .head), .absent, "ディレクトリは本文を持たない")
    XCTAssertEqual(
      version(git, "a.txt", .commit(String(repeating: "0", count: 40))), .failed,
      "手元に無いコミットは「その版に無い」ではない")

    try repo.write(".gitattributes", "*.bad filter=bad\n")
    try repo.write("x.bad", "x\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["config", "filter.bad.smudge", "false"]).isSuccess)
    XCTAssertTrue(repo.git(["config", "filter.bad.required", "true"]).isSuccess)
    XCTAssertEqual(version(git, "x.bad", .index), .failed)

    let fresh = try TempGitRepo(initialCommit: false)
    XCTAssertEqual(version(try fresh.open(), "a.txt", .head), .absent, "初回コミット前の HEAD")
  }
}
