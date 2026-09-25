import XCTest

@testable import Orbe

/// gh 着地の規則（`DispatchDataProvider.applyFetched*`）と、その保存先（`DispatchGitHubCache`）の検証。
/// gh は叩かず、取得結果に相当する値を直接着地させて sections の再描画有無で判定する。
@MainActor
final class DispatchGitHubCacheTests: OrbeTestCase {

  private func makeProvider(_ model: DispatchPaletteModel) -> DispatchDataProvider {
    DispatchDataProvider(
      cwd: "/tmp", model: model, localization: LocalizationStore(language: .ja),
      worktreeTemplate: WorktreePathTemplate.defaultTemplate)
  }

  private func issue(_ number: Int) -> GitHubIssue {
    GitHubIssue(number: number, title: "issue \(number)")
  }

  private func pullRequest(_ number: Int) -> GitHubPullRequest {
    GitHubPullRequest(
      number: number, title: "pr \(number)", headRefName: "feat/\(number)", reviewDecision: nil,
      isCrossRepository: false)
  }

  private func issueTitles(_ model: DispatchPaletteModel) -> [String] {
    model.sections.first { $0.title == "Issues" }?.items.map(\.name) ?? []
  }

  // MARK: - 着地の規則

  /// 条件4: 取得失敗（nil）は前回結果を差し替えず、再描画も起こさない。
  func testFetchFailureKeepsPreviousResultWithoutRebuild() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.applyFetchedIssues([issue(1)])
    XCTAssertEqual(issueTitles(model), ["issue 1"])

    model.sections = []  // 以降の rebuild を検出するための目印
    provider.applyFetchedIssues(nil)
    XCTAssertTrue(model.sections.isEmpty, "失敗の着地は rebuild を打たない")

    // PR 側はまだ loading なので rebuild が走る。そこに issue 行が残っていれば据え置きの証明。
    provider.applyFetchedPullRequests(nil)
    XCTAssertEqual(issueTitles(model), ["issue 1"], "失敗しても前回の issue 行は消えない")
  }

  /// キャッシュ未ヒットで失敗したときは、ローディング行を畳むため 1 回だけ rebuild する。
  func testFetchFailureWhileLoadingRebuildsOnce() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.applyFetchedIssues(nil)
    XCTAssertTrue(model.hasLoadedOnce, "ローディング行を畳むため rebuild は打つ")
    XCTAssertTrue(issueTitles(model).isEmpty, "ローディング行も残らない")
  }

  /// 条件2: 前回と等値なら再描画しない（ちらつかない）。
  func testEqualResultDoesNotRebuild() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.applyFetchedIssues([issue(1)])
    model.sections = []
    provider.applyFetchedIssues([issue(1)])
    XCTAssertTrue(model.sections.isEmpty, "等値の着地は rebuild を打たない")
  }

  /// 成功した 0 件（`[]`）は失敗（`nil`）と違い、前回結果を消す（閉じた issue が残らない）。
  func testEmptySuccessClearsPreviousResult() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.applyFetchedIssues([issue(1)])
    provider.applyFetchedIssues([])
    XCTAssertTrue(issueTitles(model).isEmpty, "0 件の成功は行を消す")
  }

  // MARK: - 保存先

  func testCacheSeparatesEntriesByCommonDir() {
    let cache = DispatchGitHubCache.shared
    cache.setIssues([issue(1)], for: "/a/.git")
    cache.setIssues([issue(2)], for: "/b/.git")
    XCTAssertEqual(cache.entry(for: "/a/.git")?.issues, [issue(1)])
    XCTAssertEqual(cache.entry(for: "/b/.git")?.issues, [issue(2)])
    XCTAssertNil(cache.entry(for: "/c/.git"), "未取得のリポジトリはエントリを持たない")
  }

  /// issues と PR は独立に到着し独立に失敗する。片方の保存が他方を巻き込まない。
  func testCacheKeepsIssuesAndPullRequestsIndependent() {
    let cache = DispatchGitHubCache.shared
    let key = "/independent/.git"
    cache.setIssues([issue(1)], for: key)
    XCTAssertNil(cache.entry(for: key)?.pullRequests, "PR は未取得のまま（0 件ではない）")
    cache.setPullRequests([pullRequest(9)], for: key)
    XCTAssertEqual(cache.entry(for: key)?.issues, [issue(1)], "PR の保存が issues を壊さない")
  }

  /// ブランチの PR は **head 単位**で保存する。「キーが無い＝未取得」「`[]`＝0 件」の区別を head ごとに
  /// 保つので、1 本の失敗が他の head の先描きを消さない。
  func testBranchPRCacheKeepsHeadsIndependent() {
    let cache = DispatchGitHubCache.shared
    let key = "/branch-prs/.git"
    let pr = GitHubBranchPR(
      number: 7, headRefName: "feat/x", state: "OPEN", baseRefName: "main",
      isCrossRepository: false)
    cache.setBranchPullRequests([pr], head: "feat/x", for: key)
    cache.setBranchPullRequests([], head: "feat/y", for: key)
    let entry = cache.entry(for: key)
    XCTAssertEqual(entry?.branchPullRequests["feat/x"], [pr])
    XCTAssertEqual(entry?.branchPullRequests["feat/y"], [], "0 件も「確かめた」として残る")
    XCTAssertNil(entry?.branchPullRequests["feat/z"], "キーが無い＝未取得（0 件ではない）")
  }

  // MARK: - open 一覧の取得

  /// open 一覧は窓ではなく上限までの全件を取る（直近 30 件の窓だと、古い issue / PR は番号やタイトルを
  /// 打っても候補に出ない）。上限は巨大リポジトリで取得全体が時間上限を越えて失敗しないための安全弁で、
  /// 緩めると上限超えのリポジトリで 1 件も出なくなり、締めると古いものが出なくなる。
  func testOpenListsFetchAllUpToTheSafetyLimit() {
    XCTAssertEqual(
      GitHubCLI.openIssuesArguments,
      ["issue", "list", "--state", "open", "--limit", "1000", "--json", "number,title"])
    XCTAssertEqual(
      GitHubCLI.openPullRequestsArguments,
      [
        "pr", "list", "--state", "open", "--limit", "500", "--json",
        "number,title,headRefName,reviewDecision,isCrossRepository",
      ])
  }

  // MARK: - 一覧取得の合流

  /// gh を叩く代わりに、撃たれた取得の完了口を溜めておき、テストが好きな時に着地させる。
  private final class PendingFetches<T> {
    private(set) var completions: [(T?) -> Void] = []
    var fetch: (@escaping (T?) -> Void) -> Void { { self.completions.append($0) } }
    func land(_ index: Int, _ result: T?) {
      guard completions.indices.contains(index) else {
        return XCTFail("\(index + 1) 本目の取得は撃たれていない")
      }
      completions[index](result)
    }
  }

  /// 取得中に開き直したパレットは取り直さず、進行中の取得の着地を受け取る。ここが崩れると、巨大
  /// リポジトリで開き直すたびに十数往復の取得が積み上がり、遅れて着いた古い取得が新しい結果を上書きする。
  func testRefreshWhileFetchingJoinsTheInFlightFetch() {
    let cache = DispatchGitHubCache.shared
    let key = "/join/.git"
    let pending = PendingFetches<[GitHubIssue]>()
    var first: [GitHubIssue]?
    var second: [GitHubIssue]?

    cache.refreshIssues(for: key, fetch: pending.fetch) { first = $0 }
    cache.refreshIssues(for: key, fetch: pending.fetch) { second = $0 }
    XCTAssertEqual(pending.completions.count, 1, "取得中の 2 本目は撃たない")

    pending.land(0, [issue(1)])
    XCTAssertEqual(first, [issue(1)])
    XCTAssertEqual(second, [issue(1)], "開き直したパレットにも同じ着地が届く")
    XCTAssertEqual(
      cache.entry(for: key)?.issues, [issue(1)], "受け手が何もしなくても次回の先描き用に残る")
  }

  /// 失敗（`nil`）は全受け手へ届く（受け手側の規則で据え置きになる）が、前回結果は消さない。
  func testFailedFetchReachesEveryReceiverAndKeepsThePreviousResult() {
    let cache = DispatchGitHubCache.shared
    let key = "/join-failure/.git"
    cache.setIssues([issue(1)], for: key)
    let pending = PendingFetches<[GitHubIssue]>()
    var landings: [[GitHubIssue]?] = []

    cache.refreshIssues(for: key, fetch: pending.fetch) { landings.append($0) }
    cache.refreshIssues(for: key, fetch: pending.fetch) { landings.append($0) }
    pending.land(0, nil)

    XCTAssertEqual(landings.count, 2, "失敗も両方の受け手に届く")
    XCTAssertTrue(landings.allSatisfy { $0 == nil })
    XCTAssertEqual(cache.entry(for: key)?.issues, [issue(1)], "失敗は前回結果を消さない")
  }

  /// 着地した後の取り直しは、終わった取得に吸われず新しい取得として始まる。着地を受けた受け手の中から
  /// 取り直しても同じ——吸われると、その受け手には何も届かず行がローディングのまま残る。
  func testRefreshAfterLandingStartsANewFetch() {
    let cache = DispatchGitHubCache.shared
    let key = "/join-again/.git"
    let pending = PendingFetches<[GitHubIssue]>()
    var reentered: [GitHubIssue]?

    cache.refreshIssues(for: key, fetch: pending.fetch) { _ in
      cache.refreshIssues(for: key, fetch: pending.fetch) { reentered = $0 }
    }
    pending.land(0, [issue(1)])
    XCTAssertEqual(pending.completions.count, 2, "着地後の取り直しは新しく撃つ")

    pending.land(1, [issue(2)])
    XCTAssertEqual(reentered, [issue(2)])
    XCTAssertEqual(cache.entry(for: key)?.issues, [issue(2)], "新しい着地が最新として残る")
  }

  /// 合流はリポジトリ単位・種別単位に閉じる。issue の取得中でも PR は撃ち、別リポジトリも撃つ——
  /// 巻き込むと PR の表示が issue の着地を待ち、別リポジトリのパレットに他所の行が届く。
  func testJoinIsScopedToRepositoryAndKind() {
    let cache = DispatchGitHubCache.shared
    let key = "/join-scope/.git"
    let issues = PendingFetches<[GitHubIssue]>()
    let pullRequests = PendingFetches<[GitHubPullRequest]>()
    var landedPullRequests: [GitHubPullRequest]?

    cache.refreshIssues(for: key, fetch: issues.fetch) { _ in }
    cache.refreshIssues(for: "/join-scope-other/.git", fetch: issues.fetch) { _ in }
    cache.refreshPullRequests(for: key, fetch: pullRequests.fetch) { landedPullRequests = $0 }
    XCTAssertEqual(issues.completions.count, 2, "別リポジトリの取得は合流しない")
    XCTAssertEqual(pullRequests.completions.count, 1, "issue の取得中でも PR は撃つ")

    pullRequests.land(0, [pullRequest(9)])
    XCTAssertEqual(landedPullRequests, [pullRequest(9)], "PR は issue の着地を待たずに届く")
    XCTAssertEqual(cache.entry(for: key)?.pullRequests, [pullRequest(9)])
    XCTAssertNil(cache.entry(for: key)?.issues, "PR の着地は issue を巻き込まない")

    issues.land(0, [])
    issues.land(1, [])
  }

  // MARK: - ブランチの PR の取得

  /// ブランチの PR は一覧の窓ではなく **worktree にあるブランチの名指し**で、`--state all` の
  /// 1 往復で open / closed の両方を引く。直近 N 件の窓では、窓落ちした PR のぶんだけ
  /// 「マージ済みなのに merged チップが出ない」「レビュー中なのに安全確認を素通りする」が起きる。
  /// `--limit` は gh が 1 往復で取れる上限（100）。往復コストは件数に依らないので、絞ると
  /// fork（cross-repo）の同名ブランチの PR で埋まって自リポジトリの PR が窓落ちする側にしか働かない。
  func testBranchPRFetchNamesTheBranchInsteadOfAWindow() {
    XCTAssertEqual(
      GitHubCLI.branchPRArguments(head: "refactor/phase2-2b"),
      [
        "pr", "list", "--state", "all", "--head", "refactor/phase2-2b", "--limit", "100",
        "--json", "number,headRefName,state,baseRefName,isCrossRepository",
      ])
  }

  /// 対象は worktree にあるブランチだけ（main worktree は掃除の対象外・detached は PR の head に
  /// なり得ない）。ここが広がると worktree 本数で抑えているプロセス数の前提が崩れる。
  func testBranchPRHeadsTargetNonMainWorktreeBranchesOnly() {
    let heads = DispatchDataProvider.branchPRHeads(of: [
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
