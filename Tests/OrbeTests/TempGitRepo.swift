import Foundation
import XCTest

@testable import Orbe

/// temp dir に作る実 git リポジトリ（初期コミット付き）。根のサービス・監視・観測のテストが共有する。
/// `root` は根の正規形（`GitWorktreeRoot.normalizedPath`）で、タブの `groupKey` と同じ綴り。
final class TempGitRepo {
  let dir: URL
  let root: String

  init(name: String = "orbe-repo") throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    root = GitWorktreeRoot.normalizedPath(dir.path)
    XCTAssertTrue(git(["init", "-q", "-b", "main"]).isSuccess)
    XCTAssertTrue(git(["config", "user.email", "t@example.com"]).isSuccess)
    XCTAssertTrue(git(["config", "user.name", "t"]).isSuccess)
    try write("a.txt", "one\n")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "init"]).isSuccess)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: dir)
  }

  @discardableResult
  func git(_ args: [String], in cwd: String? = nil) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: cwd ?? dir.path)
  }

  /// 根の下の相対パスへ書く（外部のツールの書き込みに相当。中間ディレクトリは作る）。
  func write(_ relativePath: String, _ text: String, in base: String? = nil) throws {
    let url = URL(fileURLWithPath: base ?? dir.path).appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  /// 根の下のファイルの実体 URL（文書の識別と同じ綴り）。
  func url(_ relativePath: String) -> URL {
    URL(fileURLWithPath: root).appendingPathComponent(relativePath).resolvingSymlinksInPath()
  }

  /// linked worktree を作り、その根（正規形）を返す。
  func addWorktree(_ name: String, branch: String) -> String {
    let path = dir.appendingPathComponent(name).path
    XCTAssertTrue(git(["worktree", "add", "-q", path, "-b", branch]).isSuccess)
    return GitWorktreeRoot.normalizedPath(path)
  }

  func open() throws -> GitRepo {
    var opened: GitRepo?
    let done = XCTestExpectation(description: "GitRepo.open")
    GitRepo.open(cwd: dir.path) {
      opened = $0
      done.fulfill()
    }
    XCTWaiter().wait(for: [done], timeout: 20)
    return try XCTUnwrap(opened)
  }
}

/// main queue を回しながら条件の成立を待つ（completion と FSEvents は main で届く）。時間で眠らない。
func pumpMain(
  until condition: () -> Bool, timeout: TimeInterval = 10,
  _ message: @autoclosure () -> String = "",
  file: StaticString = #filePath, line: UInt = #line
) {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition(), Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  XCTAssertTrue(condition(), "\(timeout) 秒以内に成立しない: \(message())", file: file, line: line)
}
