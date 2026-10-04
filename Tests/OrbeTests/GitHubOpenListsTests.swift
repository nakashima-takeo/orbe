import XCTest

@testable import Orbe

/// open 一覧の置き場・合流点（`GitHubOpenLists`）の検証。gh は叩かず、ページや終わりを手で着地させて判定する。
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
    private(set) var fetches: [PendingOpenListFetch] = []

    func started(_ kind: GitHubItemKind, _ repo: GitHubRepoName) -> [PendingOpenListFetch] {
      fetches.filter { $0.kind == kind && $0.repo == repo }
    }

    var source: GitHubOpenLists.Source {
      GitHubOpenLists.Source(
        defaultRepository: { root, completion in
          completion(self.roots[root].map { .success($0) } ?? .failure(.notFound))
        },
        openItems: { repo, kind, page, finished in
          self.fetches.append(
            PendingOpenListFetch(repo: repo, kind: kind, page: page, finished: finished))
        },
        reviewRequests: { _, _ in },
        addSelf: { _, _, _, _ in })
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

/// 撃たれた open 一覧の取得 1 本（ページ口と終わり口）。
private struct PendingOpenListFetch {
  let repo: GitHubRepoName
  let kind: GitHubItemKind
  let page: ([GitHubOpenItem]) -> Void
  let finished: (Bool) -> Void
}
