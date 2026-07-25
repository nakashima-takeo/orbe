import XCTest

@testable import Orbe

/// repo 内に解決される worktree の除外（`GitWorktreeExclude`）の検証。
/// 判定は解決済みパスのみ（プリセット由来かカスタム由来かに依らない）で、対象は worktree の親
/// ディレクトリ、ただし親が root 自身になる場合は worktree 自身。
final class GitWorktreeExcludeTests: XCTestCase {

  // MARK: - entry（包含判定と対象の決め方）

  /// repo 外に解決されるテンプレート（既定の兄弟配置）は何も返さない＝exclude を触らない。
  func testOutsideWorkingTreeReturnsNil() {
    XCTAssertNil(
      GitWorktreeExclude.entry(
        worktreePath: "/g/orbe-worktrees/feat-x", worktreeRoot: "/g/orbe"))
    XCTAssertNil(
      GitWorktreeExclude.entry(worktreePath: "/g/orbe-feat-x", worktreeRoot: "/g/orbe"),
      "接頭辞が一致するだけの兄弟ディレクトリは中ではない")
  }

  /// root 自身は「中」ではない（自分を除外しない）。
  func testRootItselfReturnsNil() {
    XCTAssertNil(GitWorktreeExclude.entry(worktreePath: "/g/orbe", worktreeRoot: "/g/orbe"))
  }

  /// repo 内なら親ディレクトリ（容れ物）を対象にする——以後そこに増える worktree も 1 行で覆う。
  func testInsideUsesParentDirectory() {
    let entry = GitWorktreeExclude.entry(
      worktreePath: "/g/orbe/.worktrees/feat-x", worktreeRoot: "/g/orbe")
    XCTAssertEqual(entry?.relativePath, ".worktrees")
    XCTAssertEqual(entry?.pattern, "/.worktrees/", "root 起点アンカー・ディレクトリ限定")
  }

  /// 親が root 自身になる配置では worktree 自身を対象にする（root 全体を除外しない）。
  func testDirectChildUsesItself() {
    let entry = GitWorktreeExclude.entry(worktreePath: "/g/orbe/feat-x", worktreeRoot: "/g/orbe")
    XCTAssertEqual(entry?.pattern, "/feat-x/")
  }

  /// 深い入れ子でも対象は親まで。
  func testNestedUsesParentChain() {
    let entry = GitWorktreeExclude.entry(
      worktreePath: "/g/orbe/tmp/wt/feat-x", worktreeRoot: "/g/orbe")
    XCTAssertEqual(entry?.pattern, "/tmp/wt/")
  }

  /// 末尾スラッシュ・`.`・`..` は字句正規化して判定する（テンプレートの書き方で答えが揺れない）。
  func testNormalizesBeforeComparing() {
    XCTAssertEqual(
      GitWorktreeExclude.entry(
        worktreePath: "/g/orbe/./.worktrees/feat-x", worktreeRoot: "/g/orbe/"
      )?.pattern, "/.worktrees/")
    XCTAssertNil(
      GitWorktreeExclude.entry(worktreePath: "/g/orbe/../other/wt", worktreeRoot: "/g/orbe"))
  }

  // MARK: - append（冪等な追記）

  func testAppendIsIdempotent() throws {
    let commonDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-exclude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: commonDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: commonDir) }
    let entry = GitWorktreeExclude.Entry(relativePath: ".worktrees")
    let file = commonDir.appendingPathComponent("info/exclude")

    XCTAssertTrue(GitWorktreeExclude.append(entry, toCommonDir: commonDir.path))
    let first = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(first.contains("/.worktrees/"))
    XCTAssertTrue(first.contains(GitWorktreeExclude.comment), "出所が読める見出しを付ける")

    XCTAssertTrue(GitWorktreeExclude.append(entry, toCommonDir: commonDir.path))
    XCTAssertEqual(
      try String(contentsOf: file, encoding: .utf8), first, "二度目は 1 バイトも変えない")
  }

  /// 既存内容の末尾に改行が無くても行が潰れない。
  func testAppendKeepsExistingContent() throws {
    let commonDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-exclude-\(UUID().uuidString)")
    let infoDir = commonDir.appendingPathComponent("info")
    try FileManager.default.createDirectory(at: infoDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: commonDir) }
    let file = infoDir.appendingPathComponent("exclude")
    try "# existing\n/tmp-dir/".write(to: file, atomically: true, encoding: .utf8)

    GitWorktreeExclude.append(
      GitWorktreeExclude.Entry(relativePath: ".worktrees"), toCommonDir: commonDir.path)
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.first, "# existing")
    XCTAssertTrue(lines.contains("/tmp-dir/"))
    XCTAssertTrue(lines.contains("/.worktrees/"))
  }
}

/// 実 git 層: 一時リポジトリで `GitRepo.excludeWorktreeIfInside` を走らせ、
/// 「repo 内に作っても `git status` が汚れない」「二度目で重複しない」「repo 外では触らない」を確かめる。
final class GitWorktreeExcludeIntegrationTests: XCTestCase {
  private var dir: URL!
  private var repo: GitRepo!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-exclude-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    XCTAssertTrue(git(["init", "-q", "-b", "main"]).isSuccess)
    repo = try open()
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: dir)
  }

  // MARK: - ヘルパ

  @discardableResult
  private func git(_ args: [String]) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: dir.path)
  }

  private func open() throws -> GitRepo {
    var opened: GitRepo?
    let done = expectation(description: "GitRepo.open")
    GitRepo.open(cwd: dir.path) {
      opened = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return try XCTUnwrap(opened)
  }

  private func exclude(path: String) {
    let done = expectation(description: "exclude")
    repo.excludeWorktreeIfInside(path: path, worktreeRoot: repo.root) { done.fulfill() }
    wait(for: [done], timeout: 10)
  }

  private func excludeFileText() -> String {
    let file = (repo.commonDir as NSString).appendingPathComponent("info/exclude")
    return (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
  }

  // MARK: - 検証

  /// repo 内に解決される作成先は除外に入り、その場所に worktree ができても status が汚れない。
  /// 二度目の作成でエントリは重複しない。
  func testInsideRepoExcludesAndKeepsStatusClean() throws {
    let inside = (repo.root as NSString).appendingPathComponent(".worktrees/feat-x")
    exclude(path: inside)
    XCTAssertEqual(occurrences(of: "/.worktrees/"), 1)

    try FileManager.default.createDirectory(
      atPath: inside, withIntermediateDirectories: true)
    try "x".write(
      toFile: (inside as NSString).appendingPathComponent("a.txt"), atomically: true,
      encoding: .utf8)
    XCTAssertEqual(
      git(["status", "--porcelain"]).stdoutText, "", "除外済みなので untracked が出ない")

    exclude(path: (repo.root as NSString).appendingPathComponent(".worktrees/feat-y"))
    XCTAssertEqual(occurrences(of: "/.worktrees/"), 1, "二度目でエントリが重複しない")
  }

  /// repo 外（既定の兄弟配置）では exclude ファイルを 1 バイトも触らない。
  func testOutsideRepoLeavesExcludeUntouched() {
    let before = excludeFileText()
    exclude(path: (repo.root as NSString).deletingLastPathComponent + "/repo-worktrees/feat-x")
    XCTAssertEqual(excludeFileText(), before)
  }

  /// 既にユーザーの `.gitignore` が無視している場所なら exclude へは書かない。
  func testAlreadyIgnoredIsLeftToUser() throws {
    try ".worktrees\n".write(
      toFile: (repo.root as NSString).appendingPathComponent(".gitignore"), atomically: true,
      encoding: .utf8)
    exclude(path: (repo.root as NSString).appendingPathComponent(".worktrees/feat-x"))
    XCTAssertEqual(occurrences(of: "/.worktrees/"), 0, "ユーザーが既に塞いでいるなら足さない")
  }

  private func occurrences(of pattern: String) -> Int {
    excludeFileText().split(separator: "\n", omittingEmptySubsequences: false)
      .filter { $0.trimmingCharacters(in: .whitespaces) == pattern }.count
  }
}
