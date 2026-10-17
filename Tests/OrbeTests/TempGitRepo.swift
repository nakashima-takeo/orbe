import Foundation
import OrbeTestSupport
import XCTest

@testable import Orbe

/// テストの作業ディレクトリに作る実 git リポジトリ（初期コミット付き）。根のサービス・監視・観測のテストが共有する。
/// `root` は根の正規形（`GitWorktreeRoot.normalizedPath`）で、タブの `groupKey` と同じ綴り。ref の形式は files に固定する
/// （監視が remote 追跡 ref の変化を ref 名で見分けるのは files だけ。利用者の `init.defaultRefFormat` に左右されない）。
final class TempGitRepo {
  let dir: URL
  let root: String

  /// `initialCommit` が false なら、初回コミット前（`a.txt` も作らない）。
  init(name: String = "orbe-repo", initialCommit: Bool = true) throws {
    dir = TestScratch.caseDir.appendingPathComponent(
      "\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    root = GitWorktreeRoot.normalizedPath(dir.path)
    XCTAssertTrue(git(["init", "-q", "-b", "main", "--ref-format=files"]).isSuccess)
    XCTAssertTrue(git(["config", "user.email", "t@example.com"]).isSuccess)
    XCTAssertTrue(git(["config", "user.name", "t"]).isSuccess)
    guard initialCommit else { return }
    try write("a.txt", "one\n")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "init"]).isSuccess)
  }

  /// ローカルの bare リポジトリを `origin` として足し、main を upstream 付きで送る。bare のパスを返す。
  @discardableResult
  func addOrigin() -> String {
    let bare = dir.path + "-origin.git"
    XCTAssertTrue(git(["init", "-q", "--bare", "-b", "main", bare]).isSuccess)
    XCTAssertTrue(git(["remote", "add", "origin", bare]).isSuccess)
    XCTAssertTrue(git(["push", "-q", "-u", "origin", "main"]).isSuccess)
    return bare
  }

  /// 別の clone から、origin の `branch` を origin の main の 1 コミット先へ進める（このリポジトリには取り込まない）。
  func advanceOrigin(writing relativePath: String, _ text: String, onto branch: String = "main")
    throws
  {
    let other = dir.path + "-other-\(UUID().uuidString)"
    XCTAssertTrue(git(["clone", "-q", dir.path + "-origin.git", other]).isSuccess)
    for args in [
      ["config", "user.email", "o@example.com"], ["config", "user.name", "o"],
    ] {
      XCTAssertTrue(git(args, in: other).isSuccess)
    }
    try write(relativePath, text, in: other)
    XCTAssertTrue(git(["add", "-A"], in: other).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "from other"], in: other).isSuccess)
    XCTAssertTrue(git(["push", "-q", "origin", "HEAD:" + branch], in: other).isSuccess)
  }

  /// `t.txt` を 1 コミット持つ別のリポジトリを、サブモジュール `path` として足してコミットする。サブモジュールの中でも
  /// 作者の設定を持たせる（`git -C <path>` でそのままコミットできる）。
  func addSubmodule(_ path: String) throws {
    let source = dir.path + "-\(path)"
    try write("t.txt", "t\n", in: source)
    for args in [
      ["init", "-q", "-b", "main", source], ["-C", source, "add", "t.txt"],
      ["-C", source, "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "t"],
      ["-c", "protocol.file.allow=always", "submodule", "add", "-q", source, path],
      ["commit", "-qm", "add submodule"],
      ["-C", path, "config", "user.email", "t@example.com"],
      ["-C", path, "config", "user.name", "t"],
    ] {
      XCTAssertTrue(git(args).isSuccess, "\(args)")
    }
  }

  /// HEAD のコミット。
  func head() -> String {
    git(["rev-parse", "HEAD"]).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// 根のサービスの書き込みの完了を記録する。
@MainActor
final class WriteOutcome {
  private(set) var finished = false
  private(set) var failure: GitWriteFailure?
  /// 完了が届いた時点の status（完了の時点で書き込み後の姿になっているかを見る）。
  private(set) var statusAtCompletion: GitStatus?
  private let files: RootFiles?

  init(_ files: RootFiles? = nil) {
    self.files = files
  }

  func receive(_ failure: GitWriteFailure?) {
    XCTAssertFalse(finished, "完了は 1 度だけ届く")
    finished = true
    self.failure = failure
    statusAtCompletion = files?.status
  }
}

extension TempGitRepo {
  /// 根のサービスを作り、管理下と分かって status を 1 度読むまで待つ。
  @MainActor
  func files(at root: String? = nil, runner: GitRunner = .shared) -> RootFiles {
    let files = RootFiles(root: root ?? self.root, runner: runner)
    pumpMain(until: { files.status != nil }, "status の初回取得")
    return files
  }
}
