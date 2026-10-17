import OrbeTestSupport
import XCTest

@testable import Orbe

extension RootFilesWritesTests {
  /// 競合が残っている間は、どの中身のコミットも何も書かずに「競合が残っている」で断る——先にステージする行を渡しても
  /// ステージしない（merge のコミットに関係の無い変更が混ざらない）。
  func testCommitsRefuseWhileConflictsRemainAndWriteNothing() throws {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "side"]).isSuccess)
    try repo.write("a.txt", "side\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "side"]).isSuccess)
    XCTAssertTrue(repo.git(["switch", "-q", "main"]).isSuccess)
    try repo.write("a.txt", "main\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "main"]).isSuccess)
    XCTAssertFalse(repo.git(["merge", "-q", "side"]).isSuccess, "前提: a.txt が競合する")
    try repo.write("n.txt", "new\n")
    let files = repo.files()
    let (head, index) = (repo.head(), repo.git(["ls-files", "-s"]).stdoutText)

    for content in [
      GitCommitContent.staging([GitStatus.Row(path: "n.txt", originalPath: nil)]), .staged, .amend,
    ] {
      let committed = finish(files) {
        files.commit(message: "merge", content: content, completion: $0)
      }
      XCTAssertEqual(committed.failure, .conflictsRemain, "\(content)")
    }
    XCTAssertEqual(repo.head(), head)
    XCTAssertEqual(repo.git(["ls-files", "-s"]).stdoutText, index, "index は押す前のまま")
  }
}
