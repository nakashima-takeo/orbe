import XCTest

@testable import Orbe

/// 行と PR の同一性（「GitHub のどのリポジトリのどのブランチか」）と、PR 行の Enter の行き先。
///
/// 同一性が崩れると、他人の fork の同名ブランチから出た PR が自分の行にチップと「開く」を付け、⌘↵ で
/// 他人の PR が開く。行き先が崩れると、行末とフッターが言う動きと Enter の動きが食い違う（「checkout」と
/// 出ているのに赤エラー、他人の PR の Enter で自分の worktree が開く）。
extension DispatchSectionBuilderTests {

  private var mine: GitHubRepoName { GitHubRepoName(nameWithOwner: "me/r") }
  private var stranger: GitHubRepoName { GitHubRepoName(nameWithOwner: "x/r") }

  private func tracking(_ remote: String, _ branch: String, behind: Int = 0) -> GitUpstream {
    GitUpstream(
      short: "\(remote)/\(branch)", ref: "refs/remotes/\(remote)/\(branch)", remote: remote,
      remoteRef: "refs/heads/\(branch)", track: behind > 0 ? .counts(ahead: 0, behind: behind) : nil
    )
  }

  /// push 先は、git が push 先の設定の無いときに解決するとおり upstream の remote。
  private func local(_ name: String, _ upstream: GitUpstream? = nil) -> GitBranch {
    GitBranch(name: name, relativeDate: "1d前", upstream: upstream, pushRemote: upstream?.remote)
  }

  private func remote(_ name: String) -> GitBranch {
    GitBranch(name: name, relativeDate: "3h前", upstream: nil)
  }

  private func item(_ sections: [DispatchSection], _ title: String, _ name: String)
    -> DispatchItem?
  {
    section(sections, title)?.items.first { $0.name == name }
  }

  private func pullRequestRow(_ input: DispatchSectionBuilder.Input, _ number: Int)
    -> DispatchItem?
  {
    section(DispatchSectionBuilder.build(input), "Pull requests")?.items.first {
      $0.idText == "#\(number)"
    }
  }

  // MARK: - 行と PR の同一性

  /// 他人の fork の `main` / `dev` から出た PR は、自分の `main` / `dev` の行に紐づかない。チップが
  /// 付かないので、遅れている行の同期ピルも押し出されない。
  func testOtherForksPullRequestDoesNotLinkToOwnSameNamedRows() {
    let input = DispatchSectionBuilder.Input(
      worktrees: [GitWorktree(path: "/repo", branch: "main", head: "a", isMain: true)],
      localBranches: [
        local("main", tracking("origin", "main")),
        local("dev", tracking("origin", "dev", behind: 2)),
      ],
      pullRequests: [
        pullRequest(7, head: "main", repo: stranger), pullRequest(8, head: "dev", repo: stranger),
      ],
      remoteLedger: ledger, remoteFetchLanded: true)
    let sections = DispatchSectionBuilder.build(input)

    let main = item(sections, "Worktrees", "repo")
    XCTAssertNil(main?.linkedPRNumber)
    XCTAssertEqual(main?.badges.map(\.text), [], "他人の PR 番号を自分の worktree に出さない")
    let dev = item(sections, "Local branches", "dev")
    XCTAssertNil(dev?.linkedPRNumber)
    XCTAssertEqual(dev?.badges.map(\.text), [])
    XCTAssertEqual(dev?.sync?.behind, 2, "同期ピルは残る")
  }

  /// origin が自分の fork で `upstream` に本家を置く運用: 自分の fork に立てた PR が自分の行に紐づく。
  func testOwnPullRequestLinksWhenOriginIsTheFork() {
    let input = DispatchSectionBuilder.Input(
      localBranches: [local("feat", tracking("origin", "feat"))],
      pullRequests: [pullRequest(1, head: "feat", repo: mine)],
      remoteLedger: .settled(
        .init(repositories: ["origin": .github(mine), "upstream": .github(origin)])))
    XCTAssertEqual(
      item(DispatchSectionBuilder.build(input), "Local branches", "feat")?.linkedPRNumber, 1)
  }

  /// origin が本家で、自分の fork を別の remote に置く運用: fork へ push する行には fork の PR が紐づき、
  /// 本家の同名ブランチから出た PR は紐づかない。
  func testOwnPullRequestLinksWhenTheForkIsASecondRemote() {
    let input = DispatchSectionBuilder.Input(
      worktrees: [GitWorktree(path: "/wt/feat", branch: "feat", head: "a", isMain: false)],
      localBranches: [local("feat", tracking("mine", "feat"))],
      pullRequests: [
        pullRequest(2, head: "feat", repo: origin), pullRequest(1, head: "feat", repo: mine),
      ],
      remoteLedger: .settled(
        .init(repositories: ["origin": .github(origin), "mine": .github(mine)])))
    XCTAssertEqual(
      item(DispatchSectionBuilder.build(input), "Worktrees", "feat")?.linkedPRNumber, 1,
      "push 先の fork の PR にだけ紐づく")
  }

  /// ローカル名と追跡先のブランチ名が違う行は、ローカル名のブランチから出た PR に紐づく（push される
  /// のはローカル名）。
  func testRowTrackingADifferentlyNamedBranchLinksByItsLocalName() {
    let input = DispatchSectionBuilder.Input(
      localBranches: [local("feat", tracking("origin", "feature-x"))],
      pullRequests: [pullRequest(4, head: "feat"), pullRequest(3, head: "feature-x")],
      remoteLedger: ledger)
    XCTAssertEqual(
      item(DispatchSectionBuilder.build(input), "Local branches", "feat")?.linkedPRNumber, 4)
  }

  /// 台帳が確定するまでは、行のチップを出さず、Pull requests はローディング行だけになる。Issues は
  /// 台帳を待たない。
  func testPendingLedgerShowsNoChipsAndOnlyLoadingForPullRequests() {
    let input = DispatchSectionBuilder.Input(
      worktrees: [GitWorktree(path: "/wt/feat", branch: "feat", head: "a", isMain: false)],
      issues: [GitHubIssue(number: 5, title: "bug")],
      pullRequests: [pullRequest(1, head: "feat")], githubState: .ready,
      remoteLedger: .pending)
    let sections = DispatchSectionBuilder.build(input)

    XCTAssertNil(item(sections, "Worktrees", "feat")?.linkedPRNumber, "チップを出さない")
    XCTAssertEqual(
      section(sections, "Pull requests")?.items.map(\.isLoadingRow), [true],
      "PR 行の行き先が決まらないのでローディング行だけ")
    XCTAssertEqual(section(sections, "Issues")?.items.map(\.idText), ["#5"], "Issues は出る")
  }

  // MARK: - 確かめられない remote

  /// origin 以外の、正式名を確かめられない remote へ push する行だけがチップを持たない（origin の同名
  /// ブランチの PR とも紐づかない）。他の行と Pull requests は普通に出る。
  func testRowPushingToAnUnverifiedRemoteAloneStaysUnlinked() {
    let input = DispatchSectionBuilder.Input(
      worktrees: [
        GitWorktree(path: "/wt/a", branch: "a", head: "a", isMain: false),
        GitWorktree(path: "/wt/b", branch: "b", head: "b", isMain: false),
      ],
      localBranches: [local("a", tracking("gone", "a")), local("b", tracking("origin", "b"))],
      pullRequests: [pullRequest(1, head: "a"), pullRequest(2, head: "b")],
      remoteLedger: .settled(
        .init(repositories: ["origin": .github(origin), "gone": .unverified])))
    let sections = DispatchSectionBuilder.build(input)

    XCTAssertNil(item(sections, "Worktrees", "a")?.linkedPRNumber)
    XCTAssertEqual(item(sections, "Worktrees", "b")?.linkedPRNumber, 2)
    XCTAssertEqual(
      section(sections, "Pull requests")?.items.map(\.idText), ["#1", "#2"],
      "情報行もローディング行も出ない")
    XCTAssertEqual(
      pullRequestRow(input, 1)?.action, .pullRequest(number: 1, route: .browser),
      "確かめられない行の worktree を開かない")
    XCTAssertEqual(
      pullRequestRow(input, 2)?.action,
      .pullRequest(number: 2, route: .open(.worktree(path: "/wt/b"))))
  }

  /// origin を確かめられないと、Pull requests の見出しの直下に選べない情報行が 1 行出て、PR 行は
  /// すべてブラウザで開く。どの行にもチップが付かない——origin 以外で確かめられた remote へ push する
  /// 行も紐付けない（情報行の「PR はブラウザで開きます」と動きを揃える）。一覧の取得中は末尾に
  /// ローディング行が付く。
  func testUnverifiedOriginShowsTheInfoRowAndBrowsesEveryPullRequest() {
    let input = DispatchSectionBuilder.Input(
      worktrees: [
        GitWorktree(path: "/wt/feat", branch: "feat", head: "a", isMain: false),
        GitWorktree(path: "/wt/side", branch: "side", head: "b", isMain: false),
      ],
      localBranches: [local("feat"), local("side", tracking("mine", "side"))],
      remoteBranches: [remote("mine/x")],
      pullRequests: [
        pullRequest(1, head: "feat"), pullRequest(2, head: "side", repo: mine),
        pullRequest(3, head: "x", repo: mine),
      ],
      githubState: .ready, pullRequestsFetching: true,
      remoteLedger: .settled(.init(repositories: ["origin": .unverified, "mine": .github(mine)])),
      remoteFetchLanded: true)
    let sections = DispatchSectionBuilder.build(input)

    XCTAssertEqual(
      sections.flatMap(\.items).compactMap(\.linkedPRNumber), [], "どの行にもチップが付かない")
    let rows = section(sections, "Pull requests")?.items ?? []
    XCTAssertEqual(rows.first?.infoKind, .repositoryUnverified, "見出しの直下に情報行")
    XCTAssertEqual(rows.first?.isInteractive, false, "情報行は選べない")
    XCTAssertEqual(rows.last?.isLoadingRow, true, "一覧の取得中はローディング行")
    XCTAssertEqual(
      rows.compactMap(\.action),
      [1, 2, 3].map { .pullRequest(number: $0, route: .browser) }, "PR 行はすべてブラウザで開く")
    XCTAssertEqual(
      rows.filter { $0.action != nil }.map(\.enterNote), [.browser, .browser, .browser])
  }

  // MARK: - PR 行の行き先

  /// 自分の worktree があれば、それを開く（既存 worktree）。
  func testPullRequestOpensOwnWorktreeFirst() {
    let row = pullRequestRow(
      DispatchSectionBuilder.Input(
        worktrees: [GitWorktree(path: "/wt/feat", branch: "feat", head: "a", isMain: false)],
        localBranches: [local("feat", tracking("origin", "feat"))],
        remoteBranches: [remote("origin/feat")],
        pullRequests: [pullRequest(1, head: "feat")], remoteLedger: ledger), 1)
    XCTAssertEqual(row?.action, .pullRequest(number: 1, route: .open(.worktree(path: "/wt/feat"))))
    XCTAssertEqual(row?.enterNote, .worktree(.existing))
    XCTAssertEqual(row?.footer, .launch(target: "#1", kind: .existing))
  }

  /// worktree が無く自分のローカルブランチがあれば、Local branch 行と同じ作り方（遅れの判定を含む）。
  func testPullRequestChecksOutOwnLocalBranchWhenNoWorktree() {
    let row = pullRequestRow(
      DispatchSectionBuilder.Input(
        localBranches: [local("feat", tracking("origin", "feat"))],
        remoteBranches: [remote("origin/feat")],
        pullRequests: [pullRequest(1, head: "feat")], remoteLedger: ledger), 1)
    XCTAssertEqual(row?.action, .pullRequest(number: 1, route: .open(.localBranch(name: "feat"))))
    XCTAssertEqual(row?.enterNote, .worktree(.checkout))
    XCTAssertEqual(row?.footer, .launch(target: "#1", kind: .checkout))
  }

  /// どちらも無く、fetch の着地後に head と等しい `origin/<head>` が手元にあれば、Remote branch 行と
  /// 同じくそこから作る。
  func testPullRequestIsCutFromTheLocalOriginHeadWhenNothingIsCheckedOut() {
    let row = pullRequestRow(
      DispatchSectionBuilder.Input(
        remoteBranches: [remote("origin/feat")],
        pullRequests: [pullRequest(1, head: "feat")], remoteLedger: ledger,
        remoteFetchLanded: true), 1)
    XCTAssertEqual(
      row?.action,
      .pullRequest(
        number: 1, route: .open(.remoteBranch(name: "origin/feat", existingWorktree: nil))))
    XCTAssertEqual(row?.enterNote, .worktree(.checkout))
    XCTAssertEqual(row?.footer, .launch(target: "#1", kind: .checkout))
  }

  /// 手元に作れる元が無い PR は、Enter でブラウザを開く行になり、行末とフッターがそれを先に言う。
  func testPullRequestThatCannotBeOpenedLocallyBrowses() {
    let cases: [(String, DispatchSectionBuilder.Input)] = [
      (
        "同じ名前の別のブランチが手元にある",
        DispatchSectionBuilder.Input(
          localBranches: [local("feat", tracking("mine", "feat"))],
          remoteBranches: [remote("origin/feat"), remote("mine/feat")],
          pullRequests: [pullRequest(1, head: "feat")],
          remoteLedger: .settled(
            .init(repositories: ["origin": .github(origin), "mine": .github(mine)])))
      ),
      (
        "fetch の着地後も origin/<head> が手元に無い（shallow clone 等）",
        DispatchSectionBuilder.Input(
          pullRequests: [pullRequest(1, head: "feat")], remoteLedger: ledger,
          remoteFetchLanded: true)
      ),
      (
        "head が origin 以外の remote にしか無い",
        DispatchSectionBuilder.Input(
          remoteBranches: [remote("mine/feat")],
          pullRequests: [pullRequest(1, head: "feat", repo: mine)],
          remoteLedger: .settled(
            .init(repositories: ["origin": .github(origin), "mine": .github(mine)])))
      ),
      (
        "head のリポジトリが消えている",
        DispatchSectionBuilder.Input(
          remoteBranches: [remote("origin/feat")],
          pullRequests: [
            GitHubPullRequest(
              number: 1, title: "pr 1", headRefName: "feat", reviewDecision: nil,
              headRepository: nil)
          ], remoteLedger: ledger)
      ),
    ]
    for (label, input) in cases {
      let row = pullRequestRow(input, 1)
      XCTAssertEqual(row?.action, .pullRequest(number: 1, route: .browser), label)
      XCTAssertEqual(row?.enterNote, .browser, label)
      XCTAssertEqual(row?.footer, .browse(target: "#1"), label)
    }
  }
}
