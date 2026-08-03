import XCTest

@testable import Orbe

/// repo 内に解決される worktree の除外（`GitWorktreeExclude`）の検証。
/// 契約は「Orbe が作ったものだけを除外する」——判定は解決済みパスのみ（プリセット由来かカスタム由来かに
/// 依らない）で、対象は worktree の親ディレクトリ、ただし親が root 自身か**既存**なら worktree 自身。
final class GitWorktreeExcludeTests: OrbeTestCase {

  // MARK: - entry（包含判定と対象の決め方）

  /// repo 外に解決されるテンプレート（既定の兄弟配置）は何も返さない＝exclude を触らない。
  func testOutsideWorkingTreeReturnsNil() {
    XCTAssertNil(
      GitWorktreeExclude.entry(
        worktreePath: "/g/orbe-worktrees/feat-x", worktreeRoot: "/g/orbe", parentIsNew: true))
    XCTAssertNil(
      GitWorktreeExclude.entry(
        worktreePath: "/g/orbe-feat-x", worktreeRoot: "/g/orbe", parentIsNew: true),
      "接頭辞が一致するだけの兄弟ディレクトリは中ではない")
  }

  /// root 自身は「中」ではない（自分を除外しない）。
  func testRootItselfReturnsNil() {
    XCTAssertNil(
      GitWorktreeExclude.entry(
        worktreePath: "/g/orbe", worktreeRoot: "/g/orbe", parentIsNew: true))
  }

  /// 親を Orbe がこれから作るなら、その親（容れ物）を対象にする——以後そこに増える worktree も 1 行で覆う。
  func testInsideUsesParentDirectoryWhenParentIsNew() {
    let entry = GitWorktreeExclude.entry(
      worktreePath: "/g/orbe/.worktrees/feat-x", worktreeRoot: "/g/orbe", parentIsNew: true)
    XCTAssertEqual(entry?.relativePath, ".worktrees")
    XCTAssertEqual(entry?.pattern, "/.worktrees/", "root 起点アンカー・ディレクトリ限定")
    XCTAssertEqual(entry?.checkPath, ".worktrees/", "check-ignore にはディレクトリとして問う")
  }

  /// 親が既存なら worktree 自身だけを対象にする——ユーザーのディレクトリを丸ごと status から消さない。
  func testInsideUsesItselfWhenParentAlreadyExists() {
    let entry = GitWorktreeExclude.entry(
      worktreePath: "/g/orbe/src/feat-x", worktreeRoot: "/g/orbe", parentIsNew: false)
    XCTAssertEqual(entry?.pattern, "/src/feat-x/", "既存の src を丸ごと除外しない")
  }

  /// 親が root 自身になる配置（`{parent}/{repo}/{slug}`）では worktree 自身を対象にする。
  func testDirectChildUsesItself() {
    let entry = GitWorktreeExclude.entry(
      worktreePath: "/g/orbe/feat-x", worktreeRoot: "/g/orbe", parentIsNew: true)
    XCTAssertEqual(entry?.pattern, "/feat-x/", "root 全体を除外しない")
  }

  /// 深い入れ子でも、親を新規に作るなら対象は親まで。
  func testNestedUsesParentChain() {
    let entry = GitWorktreeExclude.entry(
      worktreePath: "/g/orbe/tmp/wt/feat-x", worktreeRoot: "/g/orbe", parentIsNew: true)
    XCTAssertEqual(entry?.pattern, "/tmp/wt/")
  }

  /// 末尾スラッシュ・`.`・`..` は字句正規化して判定する（テンプレートの書き方で答えが揺れない）。
  func testNormalizesBeforeComparing() {
    XCTAssertEqual(
      GitWorktreeExclude.entry(
        worktreePath: "/g/orbe/./.worktrees/feat-x", worktreeRoot: "/g/orbe/", parentIsNew: true
      )?.pattern, "/.worktrees/")
    XCTAssertNil(
      GitWorktreeExclude.entry(
        worktreePath: "/g/orbe/../other/wt", worktreeRoot: "/g/orbe", parentIsNew: true))
  }

  /// 改行を含むパスは 1 行の gitignore パターンで表せないので除外を諦める（行が割れて別パターンが残り、
  /// 冪等判定も二度と成立しなくなるため）。
  func testPathWithNewlineReturnsNil() {
    XCTAssertNil(
      GitWorktreeExclude.entry(
        worktreePath: "/g/orbe/a\nb/feat-x", worktreeRoot: "/g/orbe", parentIsNew: true))
  }

  // MARK: - append（冪等な追記）

  private func makeCommonDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-exclude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  func testAppendIsIdempotent() throws {
    let commonDir = try makeCommonDir()
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
    let commonDir = try makeCommonDir()
    let infoDir = commonDir.appendingPathComponent("info")
    try FileManager.default.createDirectory(at: infoDir, withIntermediateDirectories: true)
    let file = infoDir.appendingPathComponent("exclude")
    try "# existing\n/tmp-dir/".write(to: file, atomically: true, encoding: .utf8)

    GitWorktreeExclude.append(
      GitWorktreeExclude.Entry(relativePath: ".worktrees"), toCommonDir: commonDir.path)
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.first, "# existing")
    XCTAssertTrue(lines.contains("/tmp-dir/"))
    XCTAssertTrue(lines.contains("/.worktrees/"))
  }

  /// 既存が UTF-8 でなくても（git は解釈できる）1 バイトも失わずに追記する。復旧手段の無い
  /// ローカル専用ファイルなので、読めない＝空と見なして置換してはいけない。
  func testAppendPreservesNonUTF8ExistingContent() throws {
    let commonDir = try makeCommonDir()
    let infoDir = commonDir.appendingPathComponent("info")
    try FileManager.default.createDirectory(at: infoDir, withIntermediateDirectories: true)
    let file = infoDir.appendingPathComponent("exclude")
    // CP932 の "# 作業" + 除外行（UTF-8 としてはデコードできないバイト列）。
    let original = Data([0x23, 0x20, 0x8D, 0xEC, 0x8B, 0xC6, 0x0A]) + Data("/secret/\n".utf8)
    try original.write(to: file)
    XCTAssertNil(try? String(contentsOf: file, encoding: .utf8), "前提: UTF-8 では読めない")

    XCTAssertTrue(
      GitWorktreeExclude.append(
        GitWorktreeExclude.Entry(relativePath: ".worktrees"), toCommonDir: commonDir.path))
    let after = try Data(contentsOf: file)
    XCTAssertTrue(after.starts(with: original), "既存バイト列をそのまま残す")
    XCTAssertNotNil(after.range(of: Data("/.worktrees/\n".utf8)), "そのうえで追記する")
  }
}

/// 実 git 層: 一時リポジトリで作成〜除外を production と同じ順序（作成成功後に除外）で走らせ、
/// 「repo 内に作っても `git status` が汚れない」「二度目で重複しない」「repo 外では触らない」
/// 「ユーザーが既に塞いでいるなら足さない」「失敗した作成の除外を残さない」を確かめる。
final class GitWorktreeExcludeIntegrationTests: OrbeTestCase {
  private var dir: URL!
  private var repo: GitRepo!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-exclude-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    XCTAssertTrue(git(["init", "-q", "-b", "main"]).isSuccess)
    XCTAssertTrue(git(["config", "user.email", "t@example.com"]).isSuccess)
    XCTAssertTrue(git(["config", "user.name", "t"]).isSuccess)
    try "x".write(
      toFile: (dir.path as NSString).appendingPathComponent("a.txt"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "init"]).isSuccess)
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

  /// production（`DispatchDataProvider.createWorktree`）と同じ順序: 対象は作成前に決め、
  /// 実際に worktree を作れたときだけ除外を入れる。
  private func createWorktree(at path: String, branch: String) {
    let entry = GitWorktreeExclude.entry(
      worktreePath: path, worktreeRoot: repo.root,
      parentIsNew: !FileManager.default.fileExists(
        atPath: (path as NSString).deletingLastPathComponent))
    guard git(["worktree", "add", "-q", path, "-b", branch]).isSuccess else { return }
    let done = expectation(description: "exclude")
    repo.applyWorktreeExclude(entry, worktreeRoot: repo.root) { done.fulfill() }
    wait(for: [done], timeout: 10)
  }

  private func excludeFileText() -> String {
    let file = (repo.commonDir as NSString).appendingPathComponent("info/exclude")
    return (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
  }

  private func occurrences(of pattern: String) -> Int {
    excludeFileText().split(separator: "\n", omittingEmptySubsequences: false)
      .filter { $0.trimmingCharacters(in: .whitespaces) == pattern }.count
  }

  // MARK: - 検証

  /// repo 内に作ると除外が入り、worktree ができても status が汚れない。二度目で重複しない。
  func testInsideRepoExcludesAndKeepsStatusClean() throws {
    createWorktree(
      at: (repo.root as NSString).appendingPathComponent(".worktrees/feat-x"), branch: "feat-x")
    XCTAssertEqual(occurrences(of: "/.worktrees/"), 1)
    XCTAssertEqual(git(["status", "--porcelain"]).stdoutText, "", "除外済みなので untracked が出ない")

    createWorktree(
      at: (repo.root as NSString).appendingPathComponent(".worktrees/feat-y"), branch: "feat-y")
    XCTAssertEqual(occurrences(of: "/.worktrees/"), 1, "二度目でエントリが重複しない")
    XCTAssertEqual(git(["status", "--porcelain"]).stdoutText, "")
  }

  /// repo 外（既定の兄弟配置）では exclude ファイルを 1 バイトも触らない。
  func testOutsideRepoLeavesExcludeUntouched() {
    let before = excludeFileText()
    createWorktree(
      at: (repo.root as NSString).deletingLastPathComponent + "/repo-worktrees/feat-x",
      branch: "feat-x")
    XCTAssertEqual(excludeFileText(), before)
  }

  /// 既にユーザーの `.gitignore` が無視している場所なら exclude へは書かない。ディレクトリ限定形
  /// （末尾 `/`＝最も慣用的な書き方）でも取りこぼさない。
  func testAlreadyIgnoredIsLeftToUser() throws {
    try ".worktrees/\n".write(
      toFile: (repo.root as NSString).appendingPathComponent(".gitignore"), atomically: true,
      encoding: .utf8)
    createWorktree(
      at: (repo.root as NSString).appendingPathComponent(".worktrees/feat-x"), branch: "feat-x")
    XCTAssertEqual(occurrences(of: "/.worktrees/"), 0, "ユーザーが既に塞いでいるなら足さない")
  }

  /// 作成に失敗したら除外は書かない（何も起きなかった操作がユーザーの repo を書き換えない）。
  /// 既存の追跡済みディレクトリと衝突する配置がこれに当たる。
  func testFailedCreationLeavesExcludeUntouched() throws {
    let docs = (repo.root as NSString).appendingPathComponent("docs")
    try FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)
    try "d".write(
      toFile: (docs as NSString).appendingPathComponent("readme.md"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "docs"]).isSuccess)
    let before = excludeFileText()

    createWorktree(at: docs, branch: "docs")  // `git worktree add docs` は既存ディレクトリで失敗する
    XCTAssertEqual(excludeFileText(), before, "失敗した作成の除外を残さない")
    XCTAssertEqual(occurrences(of: "/docs/"), 0, "ユーザーの docs/ を隠さない")
  }

  /// 既存ディレクトリの下に作る配置では、その親でなく worktree 自身だけを除外する
  /// （親を対象にすると、そこへ後から置かれたユーザーの新規ファイルまで status から消える）。
  func testExistingParentExcludesOnlyTheWorktreeItself() throws {
    let src = (repo.root as NSString).appendingPathComponent("src")
    try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
    try "s".write(
      toFile: (src as NSString).appendingPathComponent("main.swift"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "src"]).isSuccess)

    createWorktree(at: (src as NSString).appendingPathComponent("feat-x"), branch: "feat-x")
    XCTAssertEqual(occurrences(of: "/src/feat-x/"), 1)
    XCTAssertEqual(occurrences(of: "/src/"), 0, "src を丸ごと除外しない")

    try "new".write(
      toFile: (src as NSString).appendingPathComponent("added.swift"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(
      git(["status", "--porcelain"]).stdoutText.contains("src/added.swift"),
      "src 配下の新規ファイルは今も見える")
  }
}
