import XCTest

@testable import Orbe

/// worktree パステンプレ展開器の純ロジック検証（I/O 非依存）。
/// トークン展開・相対/~/絶対の基準解決・slug サニタイズ・後方互換（既定テンプレ＝現状導出）・検証を固定する。
final class WorktreePathTemplateTests: XCTestCase {

  /// 現状の worktreeDir 導出（`<リポジトリ親>/<repo名>-worktrees/<slug>`）。後方互換の突合基準。
  private func legacyWorktreeDir(repoRoot base: String, slug: String) -> String {
    let repoName = (base as NSString).lastPathComponent
    let parent = (base as NSString).deletingLastPathComponent
    let container = (parent as NSString).appendingPathComponent("\(repoName)-worktrees")
    return (container as NSString).appendingPathComponent(slug)
  }

  // MARK: - 後方互換（既定テンプレ = 現状導出と完全一致）

  /// 既定テンプレの展開結果が、旧 worktreeDir の導出と全 dispatch 経路（各ブランチ形）で一致する。
  func testDefaultTemplateMatchesLegacyDerivation() {
    let repoRoot = "/Users/dev/orbe"
    for branch in ["feature/x", "issue/44", "main", "a/b/c", "hotfix"] {
      let expanded = WorktreePathTemplate.expand(
        WorktreePathTemplate.defaultTemplate, repoRoot: repoRoot, branch: branch)
      let legacy = legacyWorktreeDir(
        repoRoot: repoRoot, slug: WorktreePathTemplate.slug(branch))
      XCTAssertEqual(expanded, legacy, "既定テンプレは現状導出と一致（後方互換）: \(branch)")
    }
  }

  // MARK: - トークン展開

  func testRepoAndSlugTokens() {
    XCTAssertEqual(
      WorktreePathTemplate.expand(
        "../{repo}-wt/{slug}", repoRoot: "/a/b/myrepo", branch: "issue/9"),
      "/a/b/myrepo-wt/issue-9")
  }

  /// slug は `/`→`-` サニタイズのみ（現 slug ロジックと同一）。
  func testSlugSanitizesSlashes() {
    XCTAssertEqual(WorktreePathTemplate.slug("issue/44"), "issue-44")
    XCTAssertEqual(WorktreePathTemplate.slug("a/b/c"), "a-b-c")
    XCTAssertEqual(WorktreePathTemplate.slug("main"), "main")
  }

  // MARK: - 基準解決（~/絶対/相対）

  func testTildeExpandsToHome() {
    let home = NSHomeDirectory()
    XCTAssertEqual(
      WorktreePathTemplate.expand("~/wt/{repo}/{slug}", repoRoot: "/x/repo", branch: "b"),
      "\(home)/wt/repo/b")
  }

  func testAbsoluteTemplateIsUsedAsIs() {
    XCTAssertEqual(
      WorktreePathTemplate.expand("/tmp/wt/{slug}", repoRoot: "/x/repo", branch: "feat/z"),
      "/tmp/wt/feat-z")
  }

  /// 相対はリポジトリルート基準で解決する（CWD 基準にしない）。
  func testRelativeResolvesAgainstRepoRoot() {
    XCTAssertEqual(
      WorktreePathTemplate.expand("wt/{slug}", repoRoot: "/Users/dev/orbe", branch: "x"),
      "/Users/dev/orbe/wt/x")
  }

  /// 日本語ブランチ名でもパス自体は保持される（サニタイズは `/` のみ）。
  func testJapaneseBranchIsPreservedExceptSlashes() {
    XCTAssertEqual(
      WorktreePathTemplate.expand("../{repo}-wt/{slug}", repoRoot: "/a/repo", branch: "機能/追加"),
      "/a/repo-wt/機能-追加")
  }

  // MARK: - 検証

  func testValidateAcceptsValid() {
    XCTAssertNil(WorktreePathTemplate.validate(WorktreePathTemplate.defaultTemplate))
    XCTAssertNil(WorktreePathTemplate.validate("~/wt/{slug}"))
    XCTAssertNil(WorktreePathTemplate.validate("{repo}/{slug}"))
  }

  func testValidateRejectsEmpty() {
    XCTAssertEqual(WorktreePathTemplate.validate(""), .empty)
    XCTAssertEqual(WorktreePathTemplate.validate("   "), .empty)
  }

  func testValidateRejectsMissingSlug() {
    XCTAssertEqual(WorktreePathTemplate.validate("../{repo}-worktrees/branch"), .missingSlug)
    XCTAssertEqual(WorktreePathTemplate.validate("wt/fixed"), .missingSlug)
  }

  func testValidateRejectsUnknownToken() {
    XCTAssertEqual(WorktreePathTemplate.validate("{owner}/{slug}"), .unknownToken("owner"))
    XCTAssertEqual(WorktreePathTemplate.validate("{date}/{repo}/{slug}"), .unknownToken("date"))
  }
}
