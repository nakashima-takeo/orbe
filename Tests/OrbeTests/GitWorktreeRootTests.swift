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
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-wtroot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
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
