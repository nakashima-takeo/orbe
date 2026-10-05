import XCTest

@testable import Orbe

/// GitHub タブの行の組み立て（`TaskPaletteGitHubRows`）。区分・並び・畳み方・絞り込み・入力・札の件数と、
/// 行に添える自分との関係、「タスクにする」で自分を足す役割を固定する。
///
/// 壊れると何が起きるか: 結び付いた行が「さらに」の下に埋もれ、タスクにした項目を見失う。更新の新しい項目が
/// 畳まれて出ない。「レビュー依頼」の札にチーム宛の PR が入らない、件数が入力で揺れる。既に担当の項目や
/// 自分の PR で「自分をアサインする」が出て、無駄な書き込みが GitHub に飛ぶ。チーム宛のレビュー依頼の PR に
/// 担当者として自分が足される。
@MainActor
final class TaskPaletteGitHubRowsTests: OrbeTestCase {
  private let repo = GitHubRepoName(nameWithOwner: "o/orbe")
  private let me = "me"

  private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

  private func issue(
    _ number: Int, updated: Int = 0, title: String? = nil, author: String? = "someone",
    assignees: [String] = []
  ) -> GitHubOpenItem {
    GitHubOpenItem(
      number: number, title: title ?? "issue \(number)", updatedAt: day(updated), author: author,
      assignees: assignees, pullRequest: nil)
  }

  private func pr(
    _ number: Int, updated: Int = 0, author: String? = "someone", assignees: [String] = [],
    reviewers: [String] = [], teams: [String] = []
  ) -> GitHubOpenItem {
    GitHubOpenItem(
      number: number, title: "pr \(number)", updatedAt: day(updated), author: author,
      assignees: assignees,
      pullRequest: .init(
        isDraft: false, review: nil, checks: nil, reviewers: reviewers, teams: teams))
  }

  private func id(_ number: Int) -> GitHubItemID { GitHubItemID(repo: repo.value, number: number)! }

  private func linkedTask(_ id: Int, _ title: String, _ items: [GitHubItemID]) -> TaskItem {
    TaskPaletteSamples.task(id, title) { task in
      task.links = items.map { TaskLink(item: $0, kind: .issue) }
    }
  }

  private func input(
    issues: [GitHubOpenItem] = [], pullRequests: [GitHubOpenItem] = [], tasks: [TaskItem] = [],
    login: String? = "me", reviewRequests: Set<Int>? = [], filter: TaskGitHubFilter = .all,
    query: String = "", expanded: Set<GitHubItemKind> = [], loading: Set<GitHubItemKind> = []
  ) -> TaskPaletteGitHubRows.Input {
    TaskPaletteGitHubRows.Input(
      repo: repo, issues: issues, pullRequests: pullRequests, tasks: tasks, login: login,
      reviewRequests: reviewRequests, filter: filter, query: query, expanded: expanded,
      loading: loading)
  }

  /// 行を読みやすい形に（見出し・項目の番号・さらに・読み込み中・空）。
  private enum Shape: Equatable {
    case header(GitHubItemKind, Int)
    case item(Int)
    case more(GitHubItemKind, Int)
    case loading(GitHubItemKind)
    case empty
  }

  private func shape(_ input: TaskPaletteGitHubRows.Input) -> [Shape] {
    TaskPaletteGitHubRows.build(input).map {
      switch $0 {
      case .header(let kind, let count): .header(kind, count)
      case .item(let row): .item(row.item.number)
      case .more(let kind, let count): .more(kind, count)
      case .loading(let kind): .loading(kind)
      case .empty: .empty
      }
    }
  }

  private func itemRow(_ number: Int, _ input: TaskPaletteGitHubRows.Input) throws
    -> TaskPaletteGitHubItemRow
  {
    try XCTUnwrap(
      TaskPaletteGitHubRows.build(input).lazy.compactMap { row -> TaskPaletteGitHubItemRow? in
        if case .item(let item) = row, item.item.number == number { item } else { nil }
      }.first)
  }

  // MARK: - 区分と並び

  /// Issue → PR の順に区分を出し、見出しに件数を添える。結び付いていない行は更新の新しい順（取った順の
  /// 作成順ではない）。
  func testSectionsListUnlinkedItemsByMostRecentUpdate() {
    let rows = shape(
      input(
        issues: [issue(3, updated: 1), issue(2, updated: 5), issue(1, updated: 3)],
        pullRequests: [pr(9, updated: 2)]))

    XCTAssertEqual(
      rows, [.header(.issue, 3), .item(2), .item(1), .item(3), .header(.pr, 1), .item(9)])
  }

  /// 結び付いた行は更新の古さに依らず区分の上にまとめ、畳まない。結び付いていない行は先頭 5 件と
  /// 「さらに」で、さらにの数に結び付いた行は入らない。
  func testLinkedRowsComeFirstAndUnlinkedRowsCollapseToFiveWithMore() {
    let issues = (1...8).map { issue($0, updated: $0) }
    let rows = shape(input(issues: issues, tasks: [linkedTask(1, "t", [id(1)])]))

    XCTAssertEqual(
      rows,
      [
        .header(.issue, 8), .item(1), .item(8), .item(7), .item(6), .item(5), .item(4),
        .more(.issue, 2),
      ])
  }

  func testExpandedSectionShowsAllUnlinkedRows() {
    let issues = (1...7).map { issue($0, updated: $0) }
    let rows = shape(input(issues: issues, expanded: [.issue]))

    XCTAssertEqual(rows, [.header(.issue, 7)] + (1...7).reversed().map { .item($0) })
  }

  /// ちょうど 5 件なら「さらに」を出さない。
  func testFiveUnlinkedRowsNeedNoMoreRow() {
    let rows = shape(input(issues: (1...5).map { issue($0, updated: $0) }))

    XCTAssertFalse(rows.contains { if case .more = $0 { true } else { false } })
  }

  /// 当たる項目の無い区分は見出しごと出さず、両方とも無ければ「該当なし」の 1 行。
  func testEmptySectionsAreOmittedAndNothingMatchingShowsTheEmptyRow() {
    XCTAssertEqual(shape(input(pullRequests: [pr(9)])), [.header(.pr, 1), .item(9)])
    XCTAssertEqual(shape(input(issues: [issue(1)], query: "zzz")), [.empty])
  }

  /// 取得中の区分は、当たる項目の後ろに読み込み中の行を足し、0 件でも見出しを残す。取得中の区分がある間は
  /// 「該当なし」と言い切らない。
  func testLoadingSectionKeepsItsHeaderAndEndsWithTheLoadingRow() {
    XCTAssertEqual(
      shape(input(issues: [issue(1)], loading: [.issue, .pr])),
      [.header(.issue, 1), .item(1), .loading(.issue), .header(.pr, 0), .loading(.pr)])
    XCTAssertEqual(
      shape(input(issues: [issue(1)], query: "zzz", loading: [.issue])),
      [.header(.issue, 0), .loading(.issue)])
  }

  /// 結び付いた行には、そのタスクの主の番号とタイトルを添える。
  func testLinkedRowNamesTheTaskWithItsPrimaryNumber() throws {
    let task = linkedTask(4, "タスク機能の設計", [id(212), id(221)])
    let row = try itemRow(221, input(issues: [issue(212), issue(221)], tasks: [task]))

    XCTAssertEqual(row.task, .init(id: 4, label: "#212 タスク機能の設計"))
  }

  // MARK: - 入力と絞り込み

  /// 入力はタイトルの部分一致か、`#` の有無を問わない番号の前方一致。見出しの件数は当てた後の数。
  func testQueryMatchesTitleOrNumberPrefix() {
    let issues = [issue(221, title: "タスク機能"), issue(22, title: "設定"), issue(5, title: "ログ")]

    XCTAssertEqual(
      shape(input(issues: issues, query: "#22")), [.header(.issue, 2), .item(221), .item(22)])
    XCTAssertEqual(
      shape(input(issues: issues, query: "22")), [.header(.issue, 2), .item(221), .item(22)])
    XCTAssertEqual(shape(input(issues: issues, query: "機能")), [.header(.issue, 1), .item(221)])
  }

  /// 担当が自分・作成者が自分は login で（大小文字を問わず）、レビュー依頼は検索の答え（チーム宛を含む）で
  /// 決める。
  func testFiltersSelectByLoginAndTheReviewRequestSearch() {
    let issues = [issue(1, assignees: ["ME"]), issue(2, author: "me"), issue(3)]
    let pullRequests = [pr(10), pr(11, teams: ["o/core"]), pr(12, author: "Me")]
    func rows(_ filter: TaskGitHubFilter) -> [Shape] {
      shape(
        input(
          issues: issues, pullRequests: pullRequests, reviewRequests: [10, 11], filter: filter))
    }

    XCTAssertEqual(rows(.assigned), [.header(.issue, 1), .item(1)])
    XCTAssertEqual(rows(.authored), [.header(.issue, 1), .item(2), .header(.pr, 1), .item(12)])
    XCTAssertEqual(rows(.reviewRequested), [.header(.pr, 2), .item(10), .item(11)])
  }

  /// 札の件数は一覧の全件で数え、入力に左右されない。自分の login・レビュー依頼がまだ分からない札は
  /// 件数を出さない（何も出さない）。
  func testFilterCountsIgnoreTheQueryAndAreUnknownWithoutLoginOrReviewRequests() {
    let issues = [issue(1, assignees: ["me"]), issue(2, title: "x", assignees: ["me"])]
    let known = TaskPaletteGitHubRows.counts(
      input(issues: issues, pullRequests: [pr(10)], reviewRequests: [10], query: "x"))
    XCTAssertEqual(known, .init(assigned: 2, authored: 0, reviewRequested: 1))

    let unknown = TaskPaletteGitHubRows.counts(
      input(issues: issues, login: nil, reviewRequests: nil))
    XCTAssertEqual(unknown, .init(assigned: nil, authored: nil, reviewRequested: nil))
    XCTAssertEqual(
      shape(input(issues: issues, login: nil, filter: .assigned)), [.empty],
      "自分が分からない間の「担当が自分」には何も出さない")
  }

  // MARK: - 自分との関係

  func testRelationOfAPullRequest() {
    func relation(_ item: GitHubOpenItem, requested: Set<Int> = []) -> TaskGitHubRelation {
      TaskPaletteGitHubRows.relation(item, login: me, reviewRequests: requested)
    }

    XCTAssertEqual(
      relation(pr(1, reviewers: ["Me"], teams: ["o/core"]), requested: [1]), .reviewRequestedYou)
    XCTAssertEqual(
      relation(pr(1, teams: ["o/core", "o/web"]), requested: [1]), .reviewRequestedTeam("o/core"))
    XCTAssertEqual(relation(pr(1), requested: [1]), .reviewRequestedTeam(nil), "チームが読めない依頼")
    XCTAssertEqual(relation(pr(1, author: "me")), .authoredByYou)
    XCTAssertEqual(relation(pr(1, author: "alice")), .author("alice"))
  }

  func testRelationOfAnIssue() {
    func relation(_ item: GitHubOpenItem) -> TaskGitHubRelation {
      TaskPaletteGitHubRows.relation(item, login: me, reviewRequests: [])
    }

    XCTAssertEqual(relation(issue(1, assignees: ["alice", "ME"])), .assignedYou)
    XCTAssertEqual(relation(issue(1, assignees: ["alice", "bob"])), .assignee("alice"))
    XCTAssertEqual(relation(issue(1)), .unassigned)
  }

  // MARK: - タスクにするときに自分を足す役割

  /// チーム宛のレビュー依頼だけがある PR はレビュアー、ほかは担当者。
  func testSelfRoleIsReviewerOnlyForTeamOnlyReviewRequests() {
    func role(_ item: GitHubOpenItem) -> GitHubSelfRole? {
      TaskPaletteGitHubRows.selfRole(item, login: me, reviewRequests: [1])
    }

    XCTAssertEqual(role(pr(1, teams: ["o/core"])), .reviewer)
    XCTAssertEqual(role(pr(2)), .assignee)
    XCTAssertEqual(role(issue(3)), .assignee)
  }

  /// 自分が作成者・既に担当・個人宛にレビュー依頼済み・自分が分からない項目では、足すものが無い。
  func testNoSelfRoleWhenThereIsNothingToAdd() {
    func role(_ item: GitHubOpenItem, login: String? = "me") -> GitHubSelfRole? {
      TaskPaletteGitHubRows.selfRole(item, login: login, reviewRequests: [1])
    }

    XCTAssertNil(role(issue(3, author: "ME")), "作成者")
    XCTAssertNil(role(issue(3, assignees: ["me"])), "既に担当")
    XCTAssertNil(role(pr(1, reviewers: ["me"])), "個人宛にレビュー依頼済み")
    XCTAssertNil(role(issue(3), login: nil), "自分が分からない")
  }

}
