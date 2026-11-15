import XCTest

@testable import Orbe

extension RootFilesWritesTests {
  /// 利用者の設定が `submodule.recurse=true` でも、サブモジュールの行の破棄はサブモジュールの中に触れない——中で作った
  /// コミットから中の HEAD を戻さず、中の未コミットの変更も残る。
  func testDiscardingASubmoduleLeavesItsInsideAloneEvenWhenTheUserRecursesIntoSubmodules() throws {
    try repo.addSubmodule("sub")
    XCTAssertTrue(repo.git(["config", "submodule.recurse", "true"]).isSuccess)
    try repo.write("sub/t.txt", "committed inside\n")
    XCTAssertTrue(repo.git(["-C", "sub", "commit", "-qam", "inside"]).isSuccess)
    try repo.write("sub/t.txt", "uncommitted inside\n")
    let inside = repo.git(["-C", "sub", "rev-parse", "HEAD"]).stdoutText
    let files = repo.files()
    pumpMain(
      until: { files.status?.entries["sub"]?.unstagedSubmodule == .commit(dirty: true) },
      "前提: SCM. の行")

    let discarded = finish(files) { files.discard(files.status!.discarding("sub"), completion: $0) }
    XCTAssertNil(discarded.failure)
    XCTAssertEqual(repo.git(["-C", "sub", "rev-parse", "HEAD"]).stdoutText, inside)
    XCTAssertEqual(
      try String(contentsOfFile: repo.root + "/sub/t.txt", encoding: .utf8), "uncommitted inside\n")
  }
}
