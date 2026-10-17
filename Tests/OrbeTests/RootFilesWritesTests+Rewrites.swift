import OrbeTestSupport
import XCTest

@testable import Orbe

extension RootFilesWritesTests {
  /// HEAD が push 済み（どれかの remote 追跡ブランチから届く）なら、amend も取り消しも何も書かずに断る——パネルの押せる・
  /// 押せないが遅れていても（▾ を開いている間の外の push）、push 済みのコミットを書き換えず、amend の先にステージする行も
  /// ステージしない。
  func testAPushedHeadIsNotRewritten() throws {
    repo.addOrigin()
    let files = repo.files()
    let pushed = repo.head()
    try repo.write("a.txt", "amended\n")
    try repo.write("n.txt", "new\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    let index = repo.git(["ls-files", "-s"]).stdoutText

    let staging = GitCommitContent.staging([GitStatus.Row(path: "n.txt", originalPath: nil)])
    let amended = finish(files) {
      files.commit(message: "reword", content: staging, amend: true, completion: $0)
    }
    XCTAssertEqual(amended.failure, .headPushed)
    let undone = finish(files) { files.undoLastCommit(completion: $0) }
    XCTAssertEqual(undone.failure, .headPushed)
    XCTAssertEqual(repo.head(), pushed)
    XCTAssertEqual(repo.git(["ls-files", "-s"]).stdoutText, index, "index は押す前のまま")

    let committed = finish(files) {
      files.commit(message: "local", content: .staged("a.txt"), completion: $0)
    }
    XCTAssertNil(committed.failure, "新しいコミットは書ける")
    let local = finish(files) { files.undoLastCommit(completion: $0) }
    XCTAssertNil(local.failure, "未 push の HEAD は取り消せる")
    XCTAssertEqual(repo.head(), pushed)
  }

  /// shallow clone の境界のコミットは、初回コミットと取り違えて取り消さない（ブランチを消すと履歴とつながらなくなる）。
  func testTheShallowBoundaryIsNotUndone() throws {
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "second"]).isSuccess)
    let shallow = TestScratch.caseDir.appendingPathComponent("shallow").path
    XCTAssertTrue(
      repo.git(["clone", "-q", "--depth", "1", "file://" + repo.root, shallow]).isSuccess)
    XCTAssertTrue(
      repo.git(["remote", "remove", "origin"], in: shallow).isSuccess,
      "前提: 境界のコミットを push 済みでなくする（push 済みなら境界より先に断る）")
    let boundary = repo.git(["rev-parse", "HEAD"], in: shallow).stdoutText
    let files = repo.files(at: GitWorktreeRoot.normalizedPath(shallow))

    let undone = finish(files) { files.undoLastCommit(completion: $0) }
    XCTAssertEqual(undone.failure, .shallowBoundary)
    XCTAssertEqual(repo.git(["rev-parse", "HEAD"], in: shallow).stdoutText, boundary)
  }
}
