import XCTest

@testable import Orbe

/// gh の結果の保存先（`GitHubCache`）と、ブランチの PR・probe の問い合わせの検証。
@MainActor
final class GitHubCacheTests: OrbeTestCase {

  // MARK: - 保存先

  /// ブランチの PR は **head 単位**で保存する。「キーが無い＝未取得」「`[]`＝0 件」の区別を head ごとに
  /// 保つので、1 本の失敗が他の head の先描きを消さない。
  func testBranchPRCacheKeepsHeadsIndependent() {
    let cache = GitHubCache.shared
    let key = "/branch-prs/.git"
    let pr = GitHubBranchPR(
      number: 7, headRefName: "feat/x", state: "OPEN", baseRefName: "main",
      headRepository: GitHubRepoName(nameWithOwner: "o/r"))
    cache.setBranchPullRequests([pr], head: "feat/x", for: key)
    cache.setBranchPullRequests([], head: "feat/y", for: key)
    let entry = cache.entry(for: key)
    XCTAssertEqual(entry?.branchPullRequests["feat/x"], [pr])
    XCTAssertEqual(entry?.branchPullRequests["feat/y"], [], "0 件も「確かめた」として残る")
    XCTAssertNil(entry?.branchPullRequests["feat/z"], "キーが無い＝未取得（0 件ではない）")
  }

  // MARK: - ブランチの PR の取得

  /// ブランチの PR は一覧の窓ではなく **worktree にあるブランチの名指し**で、`--state all` の
  /// 1 往復で open / closed の両方を引く。直近 N 件の窓では、窓落ちした PR のぶんだけ
  /// 「マージ済みなのに merged チップが出ない」「レビュー中なのに安全確認を素通りする」が起きる。
  /// `--limit` は gh が 1 往復で取れる上限（100）。往復コストは件数に依らないので、絞ると
  /// 他人の fork の同名ブランチの PR で埋まって自分の PR が窓落ちする側にしか働かない。
  /// head のリポジトリも owner と名前で取る（worktree と突き合わせるのは head が等しい PR だけ）。
  func testBranchPRFetchNamesTheBranchInsteadOfAWindow() {
    XCTAssertEqual(
      GitHubCLI.branchPRArguments(head: "refactor/phase2-2b"),
      [
        "pr", "list", "--state", "all", "--head", "refactor/phase2-2b", "--limit", "100",
        "--json", "number,headRefName,state,baseRefName,headRepository,headRepositoryOwner,url",
      ])
  }

  /// 対象は worktree にあるブランチだけ（main worktree は掃除の対象外・detached は PR の head に
  /// なり得ない）。ここが広がると worktree 本数で抑えているプロセス数の前提が崩れる。
  func testWorktreeBranchesTargetNonMainWorktreeBranchesOnly() {
    let heads = WorktreePaletteDataProvider.worktreeBranches(of: [
      GitWorktree(path: "/repo", branch: "main", head: "a", isMain: true),
      GitWorktree(path: "/wt/x", branch: "refactor/phase2-2b", head: "b", isMain: false),
      GitWorktree(path: "/wt/detached", branch: nil, head: "c", isMain: false),
    ])
    XCTAssertEqual(heads, ["refactor/phase2-2b"])
  }

  // MARK: - probe

  /// 認証判定はネットに触らない `gh auth token` で行う。`gh auth status` はトークン検証で API を
  /// 叩き、疎通不能を未認証と誤判定してキャッシュ済みの行を誘導情報行に置き換えてしまう。
  func testAuthProbeDoesNotUseNetworkVerifyingCommand() {
    XCTAssertEqual(
      GitHubCLI.authProbeArguments, ["auth", "token", "--hostname", "github.com"])
  }
}
