import XCTest

@testable import Orbe

/// タスクから開いた ⌘T の先頭の欄（「#221 の worktree」）を、provider が手元の git と remote の台帳から
/// 決めること。Issue・PR は手元のいずれかの remote のリポジトリのものだけを扱い、PR のブランチ名が届く
/// までの ↵ は預かる。
///
/// 壊れると何が起きるか: 自分の remote に無いリポジトリの Issue に「＋ issue/221 を作る」が出て、無関係な
/// リポジトリにブランチを切る。upstream（本体）の Issue に欄が出ない。PR のブランチ名が届く前の ↵ が
/// 今の worktree で決まり、今の worktree がタスクに付いて進行中になる。同じ行が欄と下の一覧に 2 度出る。
extension WorktreePaletteRemoteLedgerProviderTests {
  /// 撃たれた GitHub の値の取得の答え口。
  private final class ItemFetches {
    private(set) var batches: [([GitHubItemID], GitHubItemsBatch?) -> Void] = []
    var fetch: GitHubItemCache.Fetch { { _, batch in self.batches.append(batch) } }
  }

  private func makeTaskProvider(
    _ task: TaskItem, items: GitHubItemCache = GitHubItemCache(fetch: { _, _ in })
  ) -> (WorktreePaletteModel, WorktreePaletteDataProvider) {
    let store = TaskStore(
      file: TasksFile(version: TaskPersistence.version, nextId: task.id + 1, tasks: [task]))
    let model = WorktreePaletteModel(tasks: store, githubItems: items, task: task.id)
    let provider = WorktreePaletteDataProvider(
      cwd: root, model: model, localization: LocalizationStore(language: .ja),
      worktreeTemplate: WorktreePathTemplate.defaultTemplate, gitHub: GitHubCLI())
    return (model, provider)
  }

  private func task(_ mutate: (inout TaskItem) -> Void) -> TaskItem {
    TaskPaletteSamples.task(7, "fetch 中に進捗が出ない", .todo, mutate)
  }

  private func link(_ kind: GitHubItemKind, _ repo: String, _ number: Int) -> TaskLink {
    TaskPaletteSamples.link(kind, number, repo: repo)
  }

  /// 欄が決まった（まだ決まらない間ではない）状態まで待つ。
  private func settle(_ model: WorktreePaletteModel) -> Bool {
    pump { model.hasLoadedOnce && !model.taskTargetPending && model.newBranchRules != nil }
  }

  private func taskSection(_ model: WorktreePaletteModel) -> WorktreePaletteSection? {
    model.visibleSections.first { if case .task = $0.title { true } else { false } }
  }

  func testAnIssueOfTheOriginRepositoryOffersToCreateItsBranchFirst() throws {
    addRemote("origin", "me/r")
    let (model, provider) = makeTaskProvider(task { $0.links = [link(.issue, "me/r", 221)] })

    provider.load()
    XCTAssertTrue(settle(model))

    let section = try XCTUnwrap(taskSection(model), "先頭の欄が出る")
    XCTAssertEqual(section.title, .task(number: 221))
    XCTAssertEqual(section.items.map(\.action), [.createBranch(name: "issue/221")])
    XCTAssertEqual(model.selectedItem?.action, .createBranch(name: "issue/221"), "その行が選ばれる")
  }

  /// origin が自分の fork で、本体が upstream という形でも、本体の Issue に欄が出る。
  func testAnIssueOfAnUpstreamRemoteAlsoOffersItsBranch() throws {
    addRemote("origin", "me/r")
    addRemote("upstream", "org/r")
    let (model, provider) = makeTaskProvider(task { $0.links = [link(.issue, "org/r", 221)] })

    provider.load()
    XCTAssertTrue(settle(model))

    XCTAssertEqual(taskSection(model)?.items.map(\.action), [.createBranch(name: "issue/221")])
  }

  func testAnIssueOfARepositoryNotInTheRemotesOffersNoSection() throws {
    addRemote("origin", "me/r")
    let (model, provider) = makeTaskProvider(task { $0.links = [link(.issue, "x/y", 5)] })

    provider.load()
    XCTAssertTrue(settle(model))

    XCTAssertNil(taskSection(model), "欄を出さない")
    XCTAssertEqual(model.selectedItem?.isCurrent, true, "いつもの ⌘T と同じく今の worktree を選ぶ")
  }

  /// タスクが worktree を持っていれば、主の結び付きより先にその worktree が欄に出る。下の一覧には出さない。
  func testTheTasksOwnWorktreeIsOfferedFirstAndNotRepeatedBelow() throws {
    let path = try addWorktree("wt-feat", branch: "feat")
    let worktree = try XCTUnwrap(TaskWorktree(directory: path))
    let (model, provider) = makeTaskProvider(task { $0.worktree = worktree })

    provider.load()
    XCTAssertTrue(settle(model))

    let section = try XCTUnwrap(taskSection(model))
    XCTAssertEqual(section.title, .task(number: nil), "主が無ければ番号の無い見出し")
    XCTAssertEqual(section.items.count, 1)
    let action = try XCTUnwrap(section.items.first?.action)
    XCTAssertEqual(model.selectedItem?.action, action)
    XCTAssertEqual(
      model.items.filter { $0.action == action }.count, 1, "同じ worktree の行は 1 度だけ")
  }

  /// PR のブランチ名が届くまで欄は決まらず、その間の ↵ は預かる。届いたら、その PR のブランチ（ローカルに
  /// あればそれ）の行が欄に出て、預かった ↵ がその行で効く。
  func testEnterBeforeThePullRequestsBranchArrivesActsOnThatBranchOnceItDoes() throws {
    addRemote("origin", "me/r")
    XCTAssertTrue(git(["branch", "docs/readme-en"]).isSuccess)
    let pr = link(.pr, "me/r", 230)
    let fetches = ItemFetches()
    let items = GitHubItemCache(fetch: fetches.fetch)
    let (model, provider) = makeTaskProvider(task { $0.links = [pr] }, items: items)
    var executed: [WorktreePaletteDestination] = []
    model.onExecute = { executed.append($0) }
    items.ensure([pr.item])

    provider.load()
    XCTAssertTrue(pump { model.hasLoadedOnce && model.newBranchRules != nil })
    XCTAssertTrue(model.taskTargetPending, "ブランチ名が届くまで欄は決まらない")
    model.activate()
    XCTAssertEqual(executed, [], "↵ は預かる（今の worktree で決めない）")

    let head = GitHubBranchRef(repo: mine, branch: "docs/readme-en")
    try XCTUnwrap(fetches.batches.first)(
      [pr.item],
      GitHubItemsBatch(
        viewerLogin: nil,
        answers: [
          pr.item: .found(
            GitHubItemSummary(
              title: "docs: README を英訳する", state: .open,
              pullRequest: .init(
                isDraft: false, review: nil, checks: nil, author: "me", head: head)))
        ]))
    provider.rebuild()

    XCTAssertEqual(executed, [.localBranch(name: "docs/readme-en")], "届いたブランチで効く")
    let row = try XCTUnwrap(taskSection(model)?.items.first)
    XCTAssertEqual(row.pullRequest, 230, "PR のブランチと分かる")
    XCTAssertEqual(
      model.items.filter { $0.action == row.action }.count, 1, "下の BRANCHES に同じ行を出さない")
  }

  /// 手元の remote に無い fork の PR は、ブランチを取りに行かず欄を出さない。
  func testAPullRequestFromAForkNotInTheRemotesOffersNoSection() throws {
    addRemote("origin", "me/r")
    let pr = link(.pr, "me/r", 230)
    let fork = GitHubBranchRef(repo: GitHubRepoName(nameWithOwner: "stranger/r"), branch: "fix")
    let items = GitHubItemCache(
      answers: [
        pr.item: .found(
          GitHubItemSummary(
            title: "fix", state: .open,
            pullRequest: .init(
              isDraft: false, review: nil, checks: nil, author: "stranger", head: fork)))
      ], fetch: { _, _ in })
    let (model, provider) = makeTaskProvider(task { $0.links = [pr] }, items: items)

    provider.load()
    XCTAssertTrue(settle(model))

    XCTAssertNil(taskSection(model))
    XCTAssertEqual(model.selectedItem?.isCurrent, true)
  }
}
