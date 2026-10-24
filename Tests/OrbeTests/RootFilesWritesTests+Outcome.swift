import XCTest

@testable import Orbe

/// 落ちたコミットの結果は、落ちる前に先にステージする行を index に書いたか（`add -A` が通った後に落ちたか）を持つ（実 git）。
///
/// 壊れると何が起きるか。何も書かずに断ったコミットを「先にステージした」とパネルが数え、行が追いつく前に押し直したコミットが、
/// 外でステージされたものだけを入れて通る。hook に拒まれた後の押し直しが、自分のステージを数えずに断られる。
extension RootFilesWritesTests {
  /// 照合で断った・`add -A` が落ちたコミットは書いていないとして返す。先のステージの後で hook に拒まれたコミットは書いている。
  func testAFailedCommitTellsWhetherItStagedFirst() throws {
    try repo.write("a.txt", "edited\n")
    try repo.write("b.txt", "outside\n")
    let files = repo.files()
    let rows = [GitStatus.Row(path: "a.txt", originalPath: nil)]
    XCTAssertTrue(repo.git(["add", "b.txt"]).isSuccess, "外のステージ")
    let refused = finish(files) {
      files.commit(message: "m", content: .staging(rows), completion: $0)
    }
    XCTAssertEqual(refused.failure, .contentMismatch)
    XCTAssertEqual(refused.stagedFirst, false)
    XCTAssertTrue(repo.git(["reset", "-q", "b.txt"]).isSuccess)

    try repo.write(".git/index.lock", "")
    let locked = finish(files) {
      files.commit(message: "m", content: .staging(rows), completion: $0)
    }
    XCTAssertNotNil(locked.failure, "前提: index.lock で add -A が落ちる")
    XCTAssertEqual(locked.stagedFirst, false)
    try FileManager.default.removeItem(atPath: repo.root + "/.git/index.lock")

    try repo.write(".git/hooks/pre-commit", "#!/bin/sh\nexit 1\n")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: repo.root + "/.git/hooks/pre-commit")
    let rejected = finish(files) {
      files.commit(message: "m", content: .staging(rows), completion: $0)
    }
    XCTAssertNotNil(rejected.failure, "前提: hook が拒む")
    XCTAssertEqual(rejected.stagedFirst, true)
    XCTAssertEqual(repo.git(["diff", "--cached", "--name-only"]).stdoutText, "a.txt\n", "ステージは残る")
  }
}
