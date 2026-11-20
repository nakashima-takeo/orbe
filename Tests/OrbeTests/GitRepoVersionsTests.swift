import XCTest

@testable import Orbe

/// 版の本文（実 git）: あるパスのコミットの版を、作業ツリーに出したときの姿（smudge・eol を通す。baseline と同じ底）で取り、
/// 「そのコミットに無い」と「git の失敗」を区別する。
///
/// 壊れると何が起きるか。PR の diff が作業ツリーと違う改行で全行が差分になる・新規ファイルの diff が「読めなかった」になる・
/// filter の失敗が「無い」に見えて全行が追加になる。PR が動かしたサブモジュールの diff が「どちらの側にもない」になる。
final class GitRepoVersionsTests: OrbeTestCase {
  private var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  private func version(_ git: GitRepo, _ path: String, _ commit: String) -> GitVersionText? {
    var result: GitVersionText?
    let done = expectation(description: "version")
    git.version(of: path, atCommit: commit) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return result
  }

  private func text(_ value: String) -> GitVersionText { .present(Data(value.utf8)) }

  /// コミットの版は、そのコミットの本文——後のコミット・index・作業ツリーの本文でない。名前に `:` を含むパスも読める。
  func testReadsTheVersionAtACommit() throws {
    let git = try repo.open()
    let first = repo.head()
    try repo.write("a.txt", "two\n")
    try repo.write("odd:name.txt", "colon\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "two"]).isSuccess)
    try repo.write("a.txt", "staged\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    try repo.write("a.txt", "worktree\n")

    XCTAssertEqual(version(git, "a.txt", "HEAD"), text("two\n"))
    XCTAssertEqual(version(git, "a.txt", first), text("one\n"))
    XCTAssertEqual(version(git, "odd:name.txt", "HEAD"), text("colon\n"))
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

    XCTAssertEqual(version(git, "b.crlf", "HEAD"), text("one\r\ntwo\r\n"))
    XCTAssertEqual(version(git, "c.up", "HEAD"), text("SHOUT\n"))
  }

  /// 「そのコミットに無い」（新規・削除・ディレクトリ）と「git の失敗」（手元に無いコミット・smudge の失敗）は区別される。
  func testAbsenceIsNotAFailure() throws {
    let git = try repo.open()
    try repo.write("new.txt", "n\n")
    XCTAssertEqual(version(git, "new.txt", "HEAD"), .absent)
    try repo.write("dir/x.txt", "x\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "dir"]).isSuccess)
    XCTAssertEqual(version(git, "dir", "HEAD"), .absent, "ディレクトリは本文を持たない")
    XCTAssertEqual(
      version(git, "a.txt", String(repeating: "0", count: 40)), .failed,
      "手元に無いコミットは「そのコミットに無い」ではない")

    try repo.write(".gitattributes", "*.bad filter=bad\n")
    try repo.write("x.bad", "x\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "bad"]).isSuccess)
    XCTAssertTrue(repo.git(["config", "filter.bad.smudge", "false"]).isSuccess)
    XCTAssertTrue(repo.git(["config", "filter.bad.required", "true"]).isSuccess)
    XCTAssertEqual(version(git, "x.bad", "HEAD"), .failed)
  }

  /// コミットの版のサブモジュールは、gitlink の指すコミット——そのコミットが親のリポジトリに在っても。コミットの版の
  /// ディレクトリは本文を持たない。
  func testACommitsSubmoduleIsItsCommitEvenWhenTheParentHoldsIt() throws {
    try repo.addSubmodule("sub")
    try repo.write("dir/x.txt", "x\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "dir"]).isSuccess)
    let git = try repo.open()
    let head = repo.head()
    let sub = repo.git(["-C", "sub", "rev-parse", "HEAD"]).stdoutText
      .trimmingCharacters(in: .newlines)

    XCTAssertEqual(version(git, "sub", head), .submodule(sub))
    XCTAssertEqual(version(git, "dir", head), .absent, "ディレクトリは本文を持たない")

    XCTAssertTrue(repo.git(["fetch", "-q", "./sub", "HEAD"]).isSuccess)
    XCTAssertEqual(
      repo.git(["cat-file", "-t", sub]).stdoutText.trimmingCharacters(in: .newlines), "commit",
      "前提: gitlink の指すコミットが親のリポジトリに在る")
    XCTAssertEqual(version(git, "sub", head), .submodule(sub), "親に在っても")
  }
}
