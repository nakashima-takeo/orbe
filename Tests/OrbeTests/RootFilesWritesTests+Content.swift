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
