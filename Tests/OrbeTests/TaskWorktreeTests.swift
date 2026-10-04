import XCTest

@testable import Orbe

/// タスクの worktree の値が、パスを「それを含む worktree のルート」（タブの連と同じ場所のキー）に揃えること。
///
/// 壊れると何が起きるか: agent が worktree の中のサブディレクトリから `orb task set 12 --worktree .` と打つと、
/// タスクの worktree がそのサブディレクトリになり、同じ worktree のタブ（キーはルート）と等しくならない。
/// タスクの行に agent の札が出ず、⌘T の行にもタスクが出ない。実在しない場所を受けると、`list_tasks` には
/// 出ないのに、ほかのタスクへの付与を黙って拒む値が残る。
final class TaskWorktreeTests: OrbeTestCase {
  private func directory(_ name: String) throws -> String {
    let path = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent(name).path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  func testADirectoryInsideAWorktreeIsLiftedToTheWorktreeRoot() throws {
    let repo = try directory("repo")
    try FileManager.default.createDirectory(
      atPath: repo + "/.git", withIntermediateDirectories: true)
    let nested = try directory("repo/Sources/App")

    let worktree = try XCTUnwrap(TaskWorktree(directory: nested))

    XCTAssertEqual(worktree.path, GitWorktreeRoot.normalizedPath(repo))
    XCTAssertEqual(worktree.path, GitWorktreeRoot.locationKey(of: repo), "タブの連のキーと同じ値")
  }

  func testADirectoryOutsideGitIsKeptAsItsNormalizedPath() throws {
    let plain = try directory("notes")

    XCTAssertEqual(TaskWorktree(directory: plain)?.path, GitWorktreeRoot.normalizedPath(plain))
  }

  func testOnlyAnExistingAbsoluteDirectoryIsAccepted() throws {
    let plain = try directory("notes")
    let file = (plain as NSString).appendingPathComponent("a.txt")
    try "x".write(toFile: file, atomically: true, encoding: .utf8)

    XCTAssertNil(TaskWorktree(directory: "notes"), "相対パス")
    XCTAssertNil(TaskWorktree(directory: plain + "/gone"), "実在しない")
    XCTAssertNil(TaskWorktree(directory: file), "ファイル")
  }

  /// 書き込み（`init?(directory:)`）と読み込み（decode）は同じ形の規則で受け・拒む。書いた値を次の起動の
  /// 読み込みが拒むと、tasks.json が丸ごと退避されて一覧が空で始まる。
  func testWritingAndReadingAcceptTheSameDirectories() throws {
    for name in ["notes", "a\nb", "a\rb", "a\tb", "a\u{7}b", "a\u{2028}b"] {
      let path = try directory(name)
      let written = TaskWorktree(directory: path)
      let read = try? JSONDecoder().decode(
        TaskWorktree.self, from: JSONEncoder().encode(GitWorktreeRoot.locationKey(of: path)))

      XCTAssertEqual(written != nil, read != nil, "\(name.debugDescription): 書き込みと読み込みで同じ判定")
      XCTAssertEqual(written != nil, name == "notes", "\(name.debugDescription)")
    }
  }
}
