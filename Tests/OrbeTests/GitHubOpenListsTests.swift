import XCTest

@testable import Orbe

/// open 一覧の置き場・合流点（`GitHubOpenLists`）の検証。gh は叩かず、ページや終わりを手で着地させて判定する。
///
/// 壊れると何が起きるか: 開き直すたびに取得が積み上がり、遅れた取得が新しい結果を上書きする。取り直しの間に
/// 前回の一覧が縮んでまた伸びる。GitHub が黙って捨てたアサインを成功と言う。アサインの後に届いた古いページが、
/// 差し込んだ担当者を消す。
@MainActor
final class GitHubOpenListsTests: OrbeTestCase {
  private let repo = GitHubRepoName(nameWithOwner: "o/r")
  private let other = GitHubRepoName(nameWithOwner: "o/other")

  private func issue(_ number: Int) -> GitHubOpenItem {
    GitHubOpenItem(
      number: number, title: "issue \(number)", updatedAt: Date(timeIntervalSince1970: 0),
      author: nil, assignees: [], pullRequest: nil)
  }

  private func issues(_ numbers: Int...) -> [GitHubOpenItem] { numbers.map(issue) }

  private func pullRequest(_ number: Int) -> GitHubOpenItem {
    GitHubOpenItem(
      number: number, title: "pr \(number)", updatedAt: Date(timeIntervalSince1970: 0),
      author: nil, assignees: [],
      pullRequest: .init(isDraft: false, review: nil, checks: nil, reviewers: [], teams: []))
  }

  /// gh を叩く代わりに、root は `roots` の名前へすぐ解決し、撃たれた取得のページ口と終わり口を溜めておき、
  /// テストが好きな時に着地させる。
  private final class PendingFetches {
    var roots: [String: GitHubRepoName] = [:]
    /// 解決できない root と、その理由（`roots` に無い root は「見つからない」）。
    var unavailable: [String: GitHubRepositoryUnavailable] = [:]
    private(set) var fetches: [PendingOpenListFetch] = []
    private(set) var reviewRequests: [(GitHubReviewRequests?) -> Void] = []
    private(set) var writes: [PendingWrite] = []

    func started(_ kind: GitHubItemKind, _ repo: GitHubRepoName) -> [PendingOpenListFetch] {
      fetches.filter { $0.kind == kind && $0.repo == repo }
    }

    var source: GitHubOpenLists.Source {
      GitHubOpenLists.Source(
        defaultRepository: { root, completion in
          if let reason = self.unavailable[root] { return completion(.failure(reason)) }
          completion(self.roots[root].map { .success($0) } ?? .failure(.notFound))
        },
        openItems: { repo, kind, page, finished in
          self.fetches.append(
            PendingOpenListFetch(repo: repo, kind: kind, page: page, finished: finished))
        },
        reviewRequests: { _, completion in self.reviewRequests.append(completion) },
        addSelf: { role, item, login, completion in
          self.writes.append(
            PendingWrite(role: role, item: item, login: login, completion: completion))
        })
    }
  }

  private func issueList(_ lists: GitHubOpenLists, _ repo: GitHubRepoName) -> GitHubOpenLists.List?
  {
    lists.repositories[repo]?.issues
  }

  /// root が `repo` に解決する置き場。`previous` は前回の Issue の一覧。
  private func lists(_ fetches: PendingFetches, previous: [GitHubOpenItem]? = nil)
    -> GitHubOpenLists
  {
    fetches.roots["/root"] = repo
    var repository = GitHubOpenLists.Repository()
    repository.issues.items = previous
    return GitHubOpenLists(
      repositories: previous == nil ? [:] : [repo: repository], source: fetches.source,
      viewer: GitHubViewer())
  }

  /// root を解決したら、その名前で Issue・PR の一覧を取りに行き、解決できた名前を覚える。前回の一覧は
  /// 取り直しの間も読める（最初のフレームから前回の一覧が出る）。
  func testOpenResolvesTheRootAndFetchesBothListsKeepingThePreviousOne() {
    let fetches = PendingFetches()
    let lists = lists(fetches, previous: issues(2, 1))

    lists.open(root: "/root")

    XCTAssertEqual(lists.repository(for: "/root"), repo)
    XCTAssertEqual(fetches.started(.issue, repo).count, 1)
    XCTAssertEqual(fetches.started(.pr, repo).count, 1)
    XCTAssertEqual(issueList(lists, repo)?.items, issues(2, 1), "ページが届く前は前回の一覧")
    XCTAssertEqual(issueList(lists, repo)?.growing, true)
  }

  /// 取り直しの途中は、届いた範囲の後ろを前回の一覧の残りで埋める——前回 1000 件あった一覧が、
  /// 最初の 100 件で縮んでまた伸びることがない。
  func testPageFillsTheUnfetchedOldRangeWithThePreviousList() {
    let fetches = PendingFetches()
    let lists = lists(fetches, previous: issues(5, 4, 3, 2, 1))

    lists.open(root: "/root")
    fetches.started(.issue, repo)[0].page(issues(6, 5, 4))

    XCTAssertEqual(issueList(lists, repo)?.items, issues(6, 5, 4, 3, 2, 1))
    XCTAssertEqual(issueList(lists, repo)?.growing, true)
  }

  /// 取り終えたら今回届いた分だけに置き換わる（前回の残りにいた、その後に閉じた issue が消える）。
  func testCompletionReplacesWithTheFetchedListOnly() {
    let fetches = PendingFetches()
    let lists = lists(fetches, previous: issues(5, 4, 3, 2, 1))

    lists.open(root: "/root")
    let fetch = fetches.started(.issue, repo)[0]
    fetch.page(issues(6, 5))
    fetch.page([issue(3)])
    fetch.finished(true)

    XCTAssertEqual(issueList(lists, repo)?.items, issues(6, 5, 3))
    XCTAssertEqual(issueList(lists, repo)?.growing, false)
    XCTAssertEqual(issueList(lists, repo)?.failed, false)
  }

  /// 途中で失敗・打ち切りになっても、届いた範囲と前回の残りはそのまま残り、次の取り直しの前回になる。
  func testFailureKeepsTheFetchedRangeAndThePreviousRest() {
    let fetches = PendingFetches()
    let lists = lists(fetches, previous: issues(5, 4, 3, 2, 1))

    lists.open(root: "/root")
    let fetch = fetches.started(.issue, repo)[0]
    fetch.page(issues(6, 5, 4))
    fetch.finished(false)

    XCTAssertEqual(issueList(lists, repo)?.items, issues(6, 5, 4, 3, 2, 1))
    XCTAssertEqual(issueList(lists, repo)?.failed, true)
  }

  /// 取得中に開き直しても取り直さず合流する。ここが崩れると、開き直すたびに取得が積み上がり、遅れた取得が
  /// 新しい結果を上書きする。取り終えた後の取り直しは新しい取得として始まる。
  func testOpenWhileFetchingJoinsAndOpenAfterFinishStartsANewFetch() {
    let fetches = PendingFetches()
    let lists = lists(fetches)

    lists.open(root: "/root")
    fetches.started(.issue, repo)[0].page([issue(3)])
    lists.open(root: "/root")
    XCTAssertEqual(fetches.started(.issue, repo).count, 1, "取得中の 2 本目は撃たない")
    XCTAssertEqual(issueList(lists, repo)?.items, [issue(3)])

    fetches.started(.issue, repo)[0].page([issue(2)])
    fetches.started(.issue, repo)[0].finished(true)
    XCTAssertEqual(issueList(lists, repo)?.items, issues(3, 2), "合流後のページも同じ一覧に入る")

    lists.open(root: "/root")
    XCTAssertEqual(fetches.started(.issue, repo).count, 2, "取り終えた後の取り直しは新しく撃つ")
  }

  /// 合流と保存はリポジトリ単位・種別単位に閉じる。issue の取得中でも PR は撃ち、別リポジトリも撃つ——
  /// 巻き込むと PR の表示が issue の取得を待ち、別リポジトリの一覧に他所の行が届く。
  func testRefreshIsScopedToRepositoryAndKind() {
    let fetches = PendingFetches()
    let lists = lists(fetches)
    fetches.roots["/other"] = other

    lists.open(root: "/root")
    lists.open(root: "/other")
    XCTAssertEqual(fetches.started(.issue, other).count, 1, "別リポジトリの取得は合流しない")

    fetches.started(.pr, repo)[0].page([pullRequest(9)])
    fetches.started(.pr, repo)[0].finished(true)
    fetches.started(.issue, other)[0].page([issue(1)])
    fetches.started(.issue, other)[0].finished(true)
    XCTAssertEqual(lists.repositories[repo]?.pullRequests.items, [pullRequest(9)])
    XCTAssertNil(issueList(lists, repo)?.items, "PR や別リポジトリの着地は、この issue を巻き込まない")
    XCTAssertEqual(issueList(lists, other)?.items, [issue(1)])
  }

  // MARK: - root の解決

  /// 解決できなければ理由を持ち、前回解決できたリポジトリは残す——前回の一覧を描いたまま理由を出せる。
  func testUnresolvableRootKeepsTheReasonAndTheLastRepository() {
    let fetches = PendingFetches()
    let lists = lists(fetches)
    lists.open(root: "/root")

    fetches.unavailable["/root"] = .ghUnauthed
    lists.open(root: "/root")

    XCTAssertEqual(lists.roots["/root"]?.resolution, .unavailable(.ghUnauthed))
    XCTAssertEqual(lists.repository(for: "/root"), repo, "先描きに使う前回のリポジトリ")
  }

  /// gh の既定が前回と違うリポジトリになれば、新しい名前の一覧に切り替える。
  func testRootResolvingToAnotherRepositorySwitchesToItsLists() {
    let fetches = PendingFetches()
    let lists = lists(fetches)
    lists.open(root: "/root")

    fetches.roots["/root"] = other
    lists.open(root: "/root")

    XCTAssertEqual(lists.repository(for: "/root"), other)
    XCTAssertEqual(fetches.started(.issue, other).count, 1)
  }

  // MARK: - 自分とレビュー依頼

  /// 自分の login はアプリで 1 つの置き場へ、レビュー依頼の番号はリポジトリへ書く。失敗は何も変えない。
  func testReviewRequestsRecordTheLoginAndTheRequestedNumbers() throws {
    let fetches = PendingFetches()
    let viewer = GitHubViewer()
    fetches.roots["/root"] = repo
    let lists = GitHubOpenLists(source: fetches.source, viewer: viewer)
    lists.open(root: "/root")

    try XCTUnwrap(fetches.reviewRequests.first)(GitHubReviewRequests(login: "me", numbers: [7]))
    XCTAssertEqual(viewer.login, "me")
    XCTAssertEqual(lists.repositories[repo]?.reviewRequests, [7])

    lists.open(root: "/root")
    try XCTUnwrap(fetches.reviewRequests.last)(nil)
    XCTAssertEqual(lists.repositories[repo]?.reviewRequests, [7], "失敗は前回の答えを残す")
  }

  // MARK: - 自分を足す書き込み

  /// 取り終えた一覧に Issue 1 を持ち、自分が `me` の置き場。
  private func listsWithIssueOne(_ fetches: PendingFetches) -> GitHubOpenLists {
    let lists = GitHubOpenLists(source: fetches.source, viewer: GitHubViewer(login: "me"))
    fetches.roots["/root"] = repo
    lists.open(root: "/root")
    fetches.started(.issue, repo)[0].page([issue(1)])
    fetches.started(.issue, repo)[0].finished(true)
    return lists
  }

  private var issueOne: GitHubItemID { GitHubItemID(repo: "o/r", number: 1)! }

  /// 応答の担当者に自分が入っていれば成功で、その 1 件だけを応答の値で置き換える（一覧を取り直さない）。
  /// login の大小文字は問わない。
  func testAssignSucceedsWhenTheResponseListsSelfAndPatchesThatItem() throws {
    let fetches = PendingFetches()
    let lists = listsWithIssueOne(fetches)
    var result: Bool?

    lists.addSelf(as: .assignee, to: issueOne, kind: .issue) { result = $0 }
    let write = try XCTUnwrap(fetches.writes.first)
    XCTAssertEqual(write.login, "me")
    write.completion(["alice", "Me"])

    XCTAssertEqual(result, true)
    XCTAssertEqual(issueList(lists, repo)?.items?.first?.assignees, ["alice", "Me"])
    XCTAssertNil(lists.writeFailures[issueOne])
    XCTAssertEqual(fetches.started(.issue, repo).count, 1, "全量を取り直さない")
  }

  /// GitHub は push 権限の無い担当者を黙って捨てて成功を返す。応答に自分がいなければ、書き込みの失敗を
  /// 項目に記録する（画面の寿命に依らない）。応答が無いのも同じ。
  func testAssignFailsWhenTheResponseOmitsSelfOrIsMissing() throws {
    for response in [["alice"], nil] as [[String]?] {
      let fetches = PendingFetches()
      let lists = listsWithIssueOne(fetches)
      var result: Bool?

      lists.addSelf(as: .assignee, to: issueOne, kind: .issue) { result = $0 }
      try XCTUnwrap(fetches.writes.first).completion(response)

      XCTAssertEqual(result, false)
      XCTAssertEqual(lists.writeFailures[issueOne], .assignee)
      XCTAssertEqual(issueList(lists, repo)?.items?.first?.assignees, [], "一覧は変えない")
    }
  }

  /// 失敗の記録は、次に試せば消える。
  func testRetryingClearsTheRecordedFailure() throws {
    let fetches = PendingFetches()
    let lists = listsWithIssueOne(fetches)
    lists.addSelf(as: .assignee, to: issueOne, kind: .issue) { _ in }
    try XCTUnwrap(fetches.writes.first).completion(nil)

    lists.addSelf(as: .assignee, to: issueOne, kind: .issue) { _ in }

    XCTAssertNil(lists.writeFailures[issueOne])
  }

  /// レビュアーの成功は、個人宛のレビュー依頼を応答の値にし、自分へのレビュー依頼にも入れる。
  func testReviewerSuccessPatchesReviewersAndTheReviewRequests() throws {
    let fetches = PendingFetches()
    let lists = GitHubOpenLists(source: fetches.source, viewer: GitHubViewer(login: "me"))
    fetches.roots["/root"] = repo
    lists.open(root: "/root")
    fetches.started(.pr, repo)[0].page([pullRequest(9)])
    fetches.started(.pr, repo)[0].finished(true)
    try XCTUnwrap(fetches.reviewRequests.first)(GitHubReviewRequests(login: "me", numbers: []))
    let id = GitHubItemID(repo: "o/r", number: 9)!

    lists.addSelf(as: .reviewer, to: id, kind: .pr) { _ in }
    let write = try XCTUnwrap(fetches.writes.first)
    XCTAssertEqual(write.role, .reviewer)
    write.completion(["me"])

    XCTAssertEqual(
      lists.repositories[repo]?.pullRequests.items?.first?.pullRequest?.reviewers, ["me"])
    XCTAssertEqual(lists.repositories[repo]?.reviewRequests, [9])
  }

  /// 取得中に差し込んだ値は、差し込む前に問い合わせた古いページが後から届いても、取り終えても消えない。
  /// その項目を含まないページが先に届いた間は、後ろを埋める前回の一覧の側で残る。
  func testPatchSurvivesAnOlderPageArrivingAfterIt() throws {
    let fetches = PendingFetches()
    let lists = listsWithIssueOne(fetches)
    lists.open(root: "/root")
    let refetch = fetches.started(.issue, repo)[1]

    lists.addSelf(as: .assignee, to: issueOne, kind: .issue) { _ in }
    try XCTUnwrap(fetches.writes.first).completion(["me"])
    refetch.page([issue(2)])
    XCTAssertEqual(issueList(lists, repo)?.items?.last?.assignees, ["me"], "その項目を含まないページ")
    refetch.page([issue(1)])
    XCTAssertEqual(issueList(lists, repo)?.items?.last?.assignees, ["me"], "届いた古いページ")
    refetch.finished(true)

    XCTAssertEqual(issueList(lists, repo)?.items?.map(\.number), [2, 1])
    XCTAssertEqual(issueList(lists, repo)?.items?.last?.assignees, ["me"], "取り終えた後")
  }

  /// 取り直しで既に届いていた項目へ差し込んだ値は、続くページが届いて取り終えても残る。
  func testPatchOnAnAlreadyFetchedItemSurvivesTheFollowingPagesAndCompletion() throws {
    let fetches = PendingFetches()
    let lists = listsWithIssueOne(fetches)
    lists.open(root: "/root")
    let refetch = fetches.started(.issue, repo)[1]
    refetch.page([issue(1)])

    lists.addSelf(as: .assignee, to: issueOne, kind: .issue) { _ in }
    try XCTUnwrap(fetches.writes.first).completion(["me"])
    refetch.page([issue(2)])
    refetch.finished(true)

    XCTAssertEqual(issueList(lists, repo)?.items?.map(\.number), [1, 2])
    XCTAssertEqual(issueList(lists, repo)?.items?.first?.assignees, ["me"])
  }

  /// 取っている間に項目が動いて同じ番号が 2 度届いても、一覧には 1 行だけ（先に届いたもの）。
  func testTheSameNumberArrivingTwiceKeepsTheFirst() {
    let fetches = PendingFetches()
    let lists = lists(fetches)
    lists.open(root: "/root")
    let fetch = fetches.started(.issue, repo)[0]

    fetch.page([issue(3)])
    fetch.page([
      GitHubOpenItem(
        number: 3, title: "moved", updatedAt: Date(timeIntervalSince1970: 0), author: nil,
        assignees: [], pullRequest: nil),
      issue(2),
    ])
    fetch.finished(true)

    XCTAssertEqual(issueList(lists, repo)?.items, issues(3, 2))
  }

  // MARK: - 取り直し途中の埋め方（merge）

  /// 境目は前回の並び順で決める——今回分に含まれる要素のうち、前回の並びで一番後ろにあるものの後ろを
  /// つなぐ。番号の大小で決めると、移されてきた issue（古い番号が上位に並ぶ）で前回の行が重複・欠落する。
  func testMergeBoundaryFollowsThePreviousOrderNotNumbers() {
    XCTAssertEqual(
      GitHubOpenLists.merge(fresh: issues(11, 10, 3), previous: issues(10, 3, 9, 8)),
      issues(11, 10, 3, 9, 8))
  }

  /// 今回分が前回と 1 件も重ならなければ（全部が新規・まだ何も届いていない）、前回を全部つなぐ。
  func testMergeWithoutOverlapKeepsTheWholePreviousList() {
    XCTAssertEqual(
      GitHubOpenLists.merge(fresh: issues(7, 6), previous: issues(3, 2)), issues(7, 6, 3, 2))
    XCTAssertEqual(GitHubOpenLists.merge(fresh: [], previous: issues(3, 2)), issues(3, 2))
  }
}

/// 撃たれた書き込み 1 本（応答の担当者・個人宛のレビュー依頼の login を返す口）。
private struct PendingWrite {
  let role: GitHubSelfRole
  let item: GitHubItemID
  let login: String
  let completion: ([String]?) -> Void
}

/// 撃たれた open 一覧の取得 1 本（ページ口と終わり口）。
private struct PendingOpenListFetch {
  let repo: GitHubRepoName
  let kind: GitHubItemKind
  let page: ([GitHubOpenItem]) -> Void
  let finished: (Bool) -> Void
}
