import OrbeTestSupport
import XCTest

@testable import Orbe

/// cwd が属する git worktree ルートの同期探索（`GitWorktreeRoot`）。タブグループの所属キーの土台。
///
/// 壊れると何が起きるか。ルートを取り違えると同じリポジトリのタブが別々のセグメントに割れ
/// （色バーが 2 色になる）、逆に別 worktree が 1 本に連なる。linked worktree（`.git` が file）を
/// 見落とすと、worktree 群がすべて main リポジトリのキーへ潰れて Orbe の worktree ワークフローで
/// 区別がつかなくなる。正準形に揃えないと `/tmp` と `/private/tmp` で同じ場所が 2 キーになる。
///
/// 探索は `.git` の存在しか見ないので、`git init` は要らず `.git` を置くだけの実ファイルシステムで回す。
final class GitWorktreeRootTests: OrbeTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = TestScratch.caseDir
      .appendingPathComponent("orbe-wtroot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  /// `dir` 配下の相対パス（正準形＝symlink を解いて先頭の `/private` を畳んだ比較用の形）。
  private func canonical(_ rel: String) -> String {
    GitWorktreeRoot.normalizedPath(dir.appendingPathComponent(rel).path)
  }

  private func mkdir(_ rel: String) throws {
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent(rel), withIntermediateDirectories: true)
  }

  private func touch(_ rel: String, _ body: String = "") throws {
    try body.write(to: dir.appendingPathComponent(rel), atomically: true, encoding: .utf8)
  }

  // MARK: - locate

  /// `.git` ディレクトリを持つ最初の祖先がルート。cwd がルート自身でも、深い子でも同じ。
  func testLocateFindsNearestAncestorHoldingGitDirectory() throws {
    try mkdir("repo/.git")
    try mkdir("repo/src/deep")

    XCTAssertEqual(
      GitWorktreeRoot.locate(cwd: canonical("repo/src/deep")), canonical("repo"), "子から上へ辿る")
    XCTAssertEqual(GitWorktreeRoot.locate(cwd: canonical("repo")), canonical("repo"), "ルート自身も自分を返す")
  }

  /// linked worktree は `.git` が file。file でもルートと認め、外側のリポジトリより近い方が勝つ。
  func testLocateAcceptsGitFileOfLinkedWorktree() throws {
    try mkdir("repo/.git")
    try mkdir("repo/wt/pkg")
    try touch("repo/wt/.git", "gitdir: /elsewhere/.git/worktrees/wt\n")

    XCTAssertEqual(
      GitWorktreeRoot.locate(cwd: canonical("repo/wt/pkg")), canonical("repo/wt"), "近い .git file")
  }

  /// git 管理外は nil（`/` まで辿って何も無い）。
  func testLocateReturnsNilOutsideGit() throws {
    try mkdir("plain/sub")

    XCTAssertNil(GitWorktreeRoot.locate(cwd: canonical("plain/sub")))
  }

  /// 根の規則: git 管理外のパスの根は、そのパス自身の正準形。同じ場所なら書き方が違っても同じ根。
  func testRootOfAPathOutsideGitIsThePathItself() throws {
    try mkdir("plain/sub")
    try FileManager.default.createSymbolicLink(
      at: dir.appendingPathComponent("link"),
      withDestinationURL: dir.appendingPathComponent("plain"))

    XCTAssertEqual(
      GitWorktreeRoot.root(of: dir.appendingPathComponent("link/sub").path), canonical("plain/sub"),
      "symlink 越しでも正準形")
  }

  /// 存在しないパス（消えた worktree のサブディレクトリ）は、存在する祖先まで上がって判定する。
  func testLocateClimbsThroughMissingPathComponents() throws {
    try mkdir("repo/.git")

    XCTAssertEqual(
      GitWorktreeRoot.locate(cwd: canonical("repo/gone/away")), canonical("repo"),
      "無い階層を越えて祖先の .git へ")
  }

  /// cwd が不在だと入口の正規化は効かない（symlink が残る）。それでも見つけたルートは正準形で返る——
  /// symlink 経由の置き場で消えた worktree のタブが、同じ repo の他のタブと別キーに割れない。
  func testLocateReturnsCanonicalRootEvenWhenCwdIsMissingBehindSymlink() throws {
    try mkdir("repo/.git")
    try FileManager.default.createSymbolicLink(
      at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("repo")
    )

    XCTAssertEqual(
      GitWorktreeRoot.locate(cwd: dir.appendingPathComponent("link/gone").path), canonical("repo"),
      "不在の cwd を symlink 越しに渡してもルートは正準形")
  }

  // MARK: - branch

  /// ルートが checkout しているブランチを読む。linked worktree（`.git` が file）は指す先の HEAD を読む。
  /// detached と git の外は nil。
  func testBranchIsTheHeadOfTheRootIncludingALinkedWorktree() throws {
    let repo = canonical("repo")
    let linked = canonical("wt")
    let git = { (args: [String], cwd: String) in
      XCTAssertTrue(GitRunner.shared.runSync(args, cwd: cwd).isSuccess, args.joined(separator: " "))
    }
    try mkdir("repo")
    git(["init", "-q", "-b", "main"], repo)
    git(
      [
        "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty",
        "-m", "init",
      ], repo)
    git(["worktree", "add", "-q", "-b", "feat/x", linked], repo)

    XCTAssertEqual(GitWorktreeRoot.branch(at: repo), "main")
    XCTAssertEqual(GitWorktreeRoot.branch(at: linked), "feat/x")

    git(["checkout", "-q", "--detach"], linked)
    XCTAssertNil(GitWorktreeRoot.branch(at: linked), "detached")
    try mkdir("plain")
    XCTAssertNil(GitWorktreeRoot.branch(at: canonical("plain")), "git の外")
  }

  /// reftable のリポジトリの HEAD は互換の置き物（`refs/heads/.invalid`）で、ブランチはファイルから読めない。
  /// その名前をブランチとして返さず、分からない（nil）とする。
  func testBranchIsUnknownInAReftableRepository() throws {
    let repo = canonical("repo")
    try mkdir("repo")
    XCTAssertTrue(
      GitRunner.shared.runSync(["init", "-q", "-b", "main", "--ref-format=reftable"], cwd: repo)
        .isSuccess)
    XCTAssertTrue(
      try String(contentsOfFile: "\(repo)/.git/HEAD", encoding: .utf8).contains(".invalid"),
      "前提: HEAD は置き物")

    XCTAssertNil(GitWorktreeRoot.branch(at: repo))
  }

  /// 既定ブランチは、linked worktree でも本体（common dir）の `origin/HEAD` が指すブランチ。指していなければ
  /// main。git の外は nil。
  func testDefaultBranchFollowsOriginHeadOfTheCommonDir() throws {
    let repo = canonical("repo")
    let linked = canonical("wt")
    let git = { (args: [String]) in
      XCTAssertTrue(
        GitRunner.shared.runSync(args, cwd: repo).isSuccess, args.joined(separator: " "))
    }
    try mkdir("repo")
    git(["init", "-q", "-b", "trunk"])
    git([
      "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m",
      "init",
    ])
    git(["worktree", "add", "-q", "-b", "feat", linked])

    XCTAssertEqual(GitWorktreeRoot.defaultBranch(at: linked), "main", "origin/HEAD が無い")

    git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop"])
    XCTAssertEqual(GitWorktreeRoot.defaultBranch(at: repo), "develop")
    XCTAssertEqual(GitWorktreeRoot.defaultBranch(at: linked), "develop", "linked worktree")
    try mkdir("plain")
    XCTAssertNil(GitWorktreeRoot.defaultBranch(at: canonical("plain")), "git の外")
  }

  // MARK: - normalizedPath

  /// symlink と `..` を解いた正準形を返す。symlink 越しの cwd でもルートは正準形で出る。
  func testNormalizedPathResolvesSymlinksAndRelativeComponents() throws {
    try mkdir("repo/.git")
    try mkdir("repo/src")
    try FileManager.default.createSymbolicLink(
      at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("repo")
    )

    XCTAssertEqual(
      GitWorktreeRoot.normalizedPath(dir.appendingPathComponent("link/src/../src").path),
      canonical("repo/src"), "symlink と .. を解く")
    XCTAssertEqual(
      GitWorktreeRoot.locate(cwd: dir.appendingPathComponent("link/src").path), canonical("repo"),
      "symlink 越しでもルートは正準形")
    XCTAssertEqual(
      GitWorktreeRoot.normalizedPath("/private/tmp"), GitWorktreeRoot.normalizedPath("/tmp"),
      "macOS の /tmp と /private/tmp は同じ正準形")
  }
}
