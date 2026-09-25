import XCTest

@testable import Orbe

/// gh 着地の規則（`DispatchDataProvider.applyFetched*`）と、open 一覧の合流点・保存先
/// （`DispatchGitHubCache`）の検証。gh は叩かず、ページや終わりを手で着地させて判定する。
@MainActor
final class DispatchGitHubCacheTests: OrbeTestCase {

  /// remote を持たない（台帳が確定した）provider。PR セクションは台帳の確定を待たずに行を組む。
  private func makeProvider(_ model: DispatchPaletteModel) -> DispatchDataProvider {
    let provider = DispatchDataProvider(
      cwd: "/tmp", model: model, localization: LocalizationStore(language: .ja),
      worktreeTemplate: WorktreePathTemplate.defaultTemplate)
    provider.remoteListing = .read([:])
    return provider
  }

  private func issue(_ number: Int) -> GitHubIssue {
    GitHubIssue(number: number, title: "issue \(number)")
  }

  private func issues(_ numbers: Int...) -> [GitHubIssue] { numbers.map(issue) }

  private func pullRequest(_ number: Int) -> GitHubPullRequest {
    GitHubPullRequest(
      number: number, title: "pr \(number)", headRefName: "feat/\(number)", reviewDecision: nil,
      headRepository: GitHubRepoName(nameWithOwner: "o/r"))
  }

  private func section(_ model: DispatchPaletteModel, _ title: String) -> DispatchSection? {
    model.sections.first { $0.title == title }
  }

  private func issueTitles(_ model: DispatchPaletteModel) -> [String] {
    section(model, "Issues")?.items.filter(\.isInteractive).map(\.name) ?? []
  }

  /// 合流点はリポジトリ単位でプロセス全域に残るので、テストごとに別のリポジトリとして扱う。
  private func freshKey() -> String { "/\(UUID().uuidString)/.git" }

  // MARK: - 着地の規則

  /// 値が無い着地（未取得のまま・失敗）は前回結果を差し替えず、再描画も起こさない。
  func testFetchFailureKeepsPreviousResultWithoutRebuild() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.applyFetchedIssues([issue(1)], growing: false)
    XCTAssertEqual(issueTitles(model), ["issue 1"])

    model.sections = []  // 以降の rebuild を検出するための目印
    provider.applyFetchedIssues(nil, growing: false)
    XCTAssertTrue(model.sections.isEmpty, "値の無い着地は rebuild を打たない")

    // PR 側はまだ loading なので rebuild が走る。そこに issue 行が残っていれば据え置きの証明。
    provider.applyFetchedPullRequests(nil, growing: false)
    XCTAssertEqual(issueTitles(model), ["issue 1"], "値の無い着地でも前回の issue 行は消えない")
  }

  /// 前回結果が無いまま取得が続く間はローディング行を出し続け、値が無いまま取得が終わったら畳む
  /// （ローディング行が残り続けない）。
  func testLoadingRowFoldsWhenFetchEndsWithoutAnyList() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.rebuild()
    provider.applyFetchedIssues(nil, growing: true)
    XCTAssertEqual(
      section(model, "Issues")?.items.map(\.isLoadingRow), [true], "取得中はローディング行だけ")

    provider.applyFetchedIssues(nil, growing: false)
    XCTAssertNil(section(model, "Issues"), "値が無いまま終わったらローディング行を畳む")
  }

  /// 値も取得中かも前回と等しければ再描画しない（ページが届くたびにちらつかない）。
  func testEqualResultDoesNotRebuild() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.applyFetchedIssues([issue(1)], growing: true)
    model.sections = []
    provider.applyFetchedIssues([issue(1)], growing: true)
    XCTAssertTrue(model.sections.isEmpty, "等値の着地は rebuild を打たない")
  }

  /// 成功した 0 件（`[]`）は値の無い着地（`nil`）と違い、前回結果を消す（閉じた issue が残らない）。
  func testEmptySuccessClearsPreviousResult() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.applyFetchedIssues([issue(1)], growing: false)
    provider.applyFetchedIssues([], growing: false)
    XCTAssertTrue(issueTitles(model).isEmpty, "0 件の成功は行を消す")
  }

  /// 取得が続く間は、届いた行の後ろ（セクション末尾）にローディング行を置き、取り終えたら外す。
  /// 絞り込みで 0 件になったとき、「無い」のか「まだ届いていない」のかを見分ける印になる。
  func testGrowingListShowsLoadingRowAtSectionEnd() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.applyFetchedIssues(issues(2, 1), growing: true)
    provider.applyFetchedPullRequests([pullRequest(9)], growing: true)
    XCTAssertEqual(section(model, "Issues")?.items.map(\.isLoadingRow), [false, false, true])
    XCTAssertEqual(section(model, "Pull requests")?.items.map(\.isLoadingRow), [false, true])

    provider.applyFetchedIssues(issues(2, 1), growing: false)
    XCTAssertEqual(
      section(model, "Issues")?.items.map(\.isLoadingRow), [false, false],
      "一覧が同じでも、取り終えたらローディング行を外す")
    XCTAssertEqual(
      section(model, "Pull requests")?.items.last?.isLoadingRow, true, "PR は取得中のまま")
  }

  // MARK: - 保存先

  /// ブランチの PR は **head 単位**で保存する。「キーが無い＝未取得」「`[]`＝0 件」の区別を head ごとに
  /// 保つので、1 本の失敗が他の head の先描きを消さない。
  func testBranchPRCacheKeepsHeadsIndependent() {
    let cache = DispatchGitHubCache.shared
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

  // MARK: - open 一覧の合流点

  /// gh を叩く代わりに、撃たれた取得のページ口と終わり口を溜めておき、テストが好きな時に着地させる。
  private final class PendingFetches<T> {
    private var pages: [([T]) -> Void] = []
    private var finishes: [(Bool) -> Void] = []
    var started: Int { pages.count }
    var fetch: (@escaping ([T]) -> Void, @escaping (Bool) -> Void) -> Void {
      { page, finished in
        self.pages.append(page)
        self.finishes.append(finished)
      }
    }

    func deliver(_ nodes: [T], fetch index: Int = 0) {
      guard pages.indices.contains(index) else {
        return XCTFail("\(index + 1) 本目の取得は撃たれていない")
      }
      pages[index](nodes)
    }

    func finish(_ succeeded: Bool, fetch index: Int = 0) {
      guard finishes.indices.contains(index) else {
        return XCTFail("\(index + 1) 本目の取得は撃たれていない")
      }
      finishes[index](succeeded)
    }
  }

  /// 受け手に届いた 1 回ぶん（一覧の現在値・取得中か）。
  private struct Update<T: Equatable>: Equatable {
    let list: [T]?
    let growing: Bool
  }

  /// 受け手に届いた更新を届いた順に記録する。
  private final class Updates<T: Equatable> {
    private(set) var all: [Update<T>] = []
    var last: Update<T>? { all.last }
    var receive: ([T]?, Bool) -> Void { { self.all.append(Update(list: $0, growing: $1)) } }
  }

  private typealias IssueUpdate = Update<GitHubIssue>

  /// 取り直しを最後まで済ませて、キャッシュに前回の一覧を用意する。
  private func settleIssues(_ list: [GitHubIssue], for key: String) {
    let fetches = PendingFetches<GitHubIssue>()
    DispatchGitHubCache.shared.refreshIssues(for: key, fetch: fetches.fetch) { _, _ in }
    fetches.deliver(list)
    fetches.finish(true)
  }

  /// 開いた時点でキャッシュの前回結果を先に受け取る（最初のフレームから前回の一覧が出る）。
  /// 前回結果が無ければ `nil`（ローディング行の規則に乗る）。
  func testRefreshHandsTheCachedListFirst() {
    let cache = DispatchGitHubCache.shared
    let key = freshKey()
    let fetches = PendingFetches<GitHubIssue>()
    let first = Updates<GitHubIssue>()
    cache.refreshIssues(for: key, fetch: fetches.fetch, updated: first.receive)
    XCTAssertEqual(first.all, [IssueUpdate(list: nil, growing: true)], "前回結果が無ければ nil")
    fetches.deliver(issues(2, 1))
    fetches.finish(true)

    let second = Updates<GitHubIssue>()
    cache.refreshIssues(for: key, fetch: fetches.fetch, updated: second.receive)
    XCTAssertEqual(
      second.all, [IssueUpdate(list: issues(2, 1), growing: true)], "ページが届く前に前回の一覧を受け取る")
    fetches.finish(true, fetch: 1)
  }

  /// 取り直しの途中は、届いた範囲の後ろを前回の一覧の残りで埋める——前回 1000 件あった一覧が、
  /// 最初の 100 件で縮んでまた伸びることがない。
  func testPageFillsTheUnfetchedOldRangeWithThePreviousList() {
    let cache = DispatchGitHubCache.shared
    let key = freshKey()
    settleIssues(issues(5, 4, 3, 2, 1), for: key)
    let fetches = PendingFetches<GitHubIssue>()
    let updates = Updates<GitHubIssue>()

    cache.refreshIssues(for: key, fetch: fetches.fetch, updated: updates.receive)
    fetches.deliver(issues(6, 5, 4))

    XCTAssertEqual(updates.last, IssueUpdate(list: issues(6, 5, 4, 3, 2, 1), growing: true))
    XCTAssertEqual(cache.entry(for: key)?.issues, issues(6, 5, 4, 3, 2, 1), "途中の一覧もキャッシュに残る")
    fetches.finish(true)
  }

  /// 取り終えたら今回届いた分だけに置き換わる（前回の残りにいた、その後に閉じた issue が消える）。
  func testCompletionReplacesWithTheFetchedListOnly() {
    let cache = DispatchGitHubCache.shared
    let key = freshKey()
    settleIssues(issues(5, 4, 3, 2, 1), for: key)
    let fetches = PendingFetches<GitHubIssue>()
    let updates = Updates<GitHubIssue>()

    cache.refreshIssues(for: key, fetch: fetches.fetch, updated: updates.receive)
    fetches.deliver(issues(6, 5))
    fetches.deliver([issue(3)])
    fetches.finish(true)

    XCTAssertEqual(updates.last, IssueUpdate(list: issues(6, 5, 3), growing: false))
    XCTAssertEqual(cache.entry(for: key)?.issues, issues(6, 5, 3))
  }

  /// 途中で失敗・打ち切りになっても、届いた範囲と前回の残りはそのまま残り、次の取り直しの前回になる。
  func testFailureKeepsTheFetchedRangeAndThePreviousRest() {
    let cache = DispatchGitHubCache.shared
    let key = freshKey()
    settleIssues(issues(5, 4, 3, 2, 1), for: key)
    let fetches = PendingFetches<GitHubIssue>()
    let updates = Updates<GitHubIssue>()

    cache.refreshIssues(for: key, fetch: fetches.fetch, updated: updates.receive)
    fetches.deliver(issues(6, 5, 4))
    fetches.finish(false)

    XCTAssertEqual(updates.last, IssueUpdate(list: issues(6, 5, 4, 3, 2, 1), growing: false))
    let next = Updates<GitHubIssue>()
    cache.refreshIssues(for: key, fetch: fetches.fetch, updated: next.receive)
    XCTAssertEqual(next.last?.list, issues(6, 5, 4, 3, 2, 1), "次に開いたときの先描きになる")
    fetches.finish(true, fetch: 1)
  }

  /// 取得中に開き直したパレットは取り直さず合流し、それまでに届いた一覧と以降のページを受け取る。
  /// ここが崩れると、開き直すたびに取得が積み上がり、遅れた取得が新しい結果を上書きする。
  func testRefreshWhileFetchingJoinsWithTheCurrentListAndLaterPages() {
    let cache = DispatchGitHubCache.shared
    let key = freshKey()
    let fetches = PendingFetches<GitHubIssue>()
    let first = Updates<GitHubIssue>()
    let joined = Updates<GitHubIssue>()

    cache.refreshIssues(for: key, fetch: fetches.fetch, updated: first.receive)
    fetches.deliver([issue(3)])
    cache.refreshIssues(for: key, fetch: fetches.fetch, updated: joined.receive)
    XCTAssertEqual(fetches.started, 1, "取得中の 2 本目は撃たない")
    XCTAssertEqual(
      joined.all, [IssueUpdate(list: [issue(3)], growing: true)], "合流した時点までの一覧を受け取る")

    fetches.deliver([issue(2)])
    fetches.finish(true)
    let settled = IssueUpdate(list: issues(3, 2), growing: false)
    XCTAssertEqual(joined.last, settled, "合流後のページと終わりも届く")
    XCTAssertEqual(first.last, settled)
  }

  /// 取り終えた後の取り直しは、終わった取得に吸われず新しい取得として始まる。取り終えを受けた受け手の
  /// 中から取り直しても同じ——吸われると、その受け手には何も届かない。
  func testRefreshAfterFinishStartsANewFetch() {
    let cache = DispatchGitHubCache.shared
    let key = freshKey()
    let fetches = PendingFetches<GitHubIssue>()
    let reentered = Updates<GitHubIssue>()

    cache.refreshIssues(for: key, fetch: fetches.fetch) { _, growing in
      if !growing {
        cache.refreshIssues(for: key, fetch: fetches.fetch, updated: reentered.receive)
      }
    }
    fetches.deliver([issue(1)])
    fetches.finish(true)
    XCTAssertEqual(fetches.started, 2, "取り終えた後の取り直しは新しく撃つ")

    fetches.deliver([issue(2)], fetch: 1)
    fetches.finish(true, fetch: 1)
    XCTAssertEqual(reentered.last, IssueUpdate(list: [issue(2)], growing: false))
  }

  /// 合流と保存はリポジトリ単位・種別単位に閉じる。issue の取得中でも PR は撃ち、別リポジトリも撃つ——
  /// 巻き込むと PR の表示が issue の取得を待ち、別リポジトリのパレットに他所の行が届く。
  func testRefreshIsScopedToRepositoryAndKind() {
    let cache = DispatchGitHubCache.shared
    let key = freshKey()
    let other = freshKey()
    let issueFetches = PendingFetches<GitHubIssue>()
    let pullRequestFetches = PendingFetches<GitHubPullRequest>()
    let pullRequests = Updates<GitHubPullRequest>()

    cache.refreshIssues(for: key, fetch: issueFetches.fetch) { _, _ in }
    cache.refreshIssues(for: other, fetch: issueFetches.fetch) { _, _ in }
    cache.refreshPullRequests(
      for: key, fetch: pullRequestFetches.fetch, updated: pullRequests.receive)
    XCTAssertEqual(issueFetches.started, 2, "別リポジトリの取得は合流しない")
    XCTAssertEqual(pullRequestFetches.started, 1, "issue の取得中でも PR は撃つ")

    pullRequestFetches.deliver([pullRequest(9)])
    pullRequestFetches.finish(true)
    issueFetches.deliver([issue(1)], fetch: 1)
    issueFetches.finish(true, fetch: 1)
    XCTAssertEqual(pullRequests.last?.list, [pullRequest(9)], "PR は issue の取得を待たずに届く")
    XCTAssertEqual(cache.entry(for: key)?.pullRequests, [pullRequest(9)])
    XCTAssertNil(cache.entry(for: key)?.issues, "PR や別リポジトリの着地は、この issue を巻き込まない")
    XCTAssertEqual(cache.entry(for: other)?.issues, [issue(1)])

    issueFetches.finish(true)
  }

  // MARK: - 取り直し途中の埋め方（merge）

  /// 境目は前回の並び順で決める——今回分に含まれる要素のうち、前回の並びで一番後ろにあるものの後ろを
  /// つなぐ。番号の大小で決めると、移されてきた issue（古い番号が上位に並ぶ）で前回の行が重複・欠落する。
  func testMergeBoundaryFollowsThePreviousOrderNotNumbers() {
    XCTAssertEqual(
      DispatchGitHubCache.merge(fresh: issues(11, 10, 3), previous: issues(10, 3, 9, 8)),
      issues(11, 10, 3, 9, 8))
  }

  /// 今回分が前回と 1 件も重ならなければ（全部が新規・まだ何も届いていない）、前回を全部つなぐ。
  func testMergeWithoutOverlapKeepsTheWholePreviousList() {
    XCTAssertEqual(
      DispatchGitHubCache.merge(fresh: issues(7, 6), previous: issues(3, 2)), issues(7, 6, 3, 2))
    XCTAssertEqual(DispatchGitHubCache.merge(fresh: [], previous: issues(3, 2)), issues(3, 2))
  }

  // MARK: - ブランチの PR の取得

  /// ブランチの PR は一覧の窓ではなく **worktree にあるブランチの名指し**で、`--state all` の
  /// 1 往復で open / closed の両方を引く。直近 N 件の窓では、窓落ちした PR のぶんだけ
  /// 「マージ済みなのに merged チップが出ない」「レビュー中なのに安全確認を素通りする」が起きる。
  /// `--limit` は gh が 1 往復で取れる上限（100）。往復コストは件数に依らないので、絞ると
  /// 他人の fork の同名ブランチの PR で埋まって自分の PR が窓落ちする側にしか働かない。
  /// head のリポジトリも取る（worktree と突き合わせるのは head が等しい PR だけ）。
  func testBranchPRFetchNamesTheBranchInsteadOfAWindow() {
    XCTAssertEqual(
      GitHubCLI.branchPRArguments(head: "refactor/phase2-2b"),
      [
        "pr", "list", "--state", "all", "--head", "refactor/phase2-2b", "--limit", "100",
        "--json", "number,headRefName,state,baseRefName,headRepository",
      ])
  }

  /// 対象は worktree にあるブランチだけ（main worktree は掃除の対象外・detached は PR の head に
  /// なり得ない）。ここが広がると worktree 本数で抑えているプロセス数の前提が崩れる。
  func testBranchPRHeadsTargetNonMainWorktreeBranchesOnly() {
    let heads = DispatchDataProvider.worktreeBranches(of: [
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
