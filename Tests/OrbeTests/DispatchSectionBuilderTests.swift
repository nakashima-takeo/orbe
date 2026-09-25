import XCTest

@testable import Orbe

/// DispatchSectionBuilder（純粋関数）の相関・重複排除・フォールバック・action ペイロード検証。
final class DispatchSectionBuilderTests: OrbeTestCase {

  func section(_ sections: [DispatchSection], _ title: String) -> DispatchSection? {
    sections.first { $0.title == title }
  }

  let origin = GitHubRepoName(nameWithOwner: "o/r")

  /// origin だけを持つ確定した台帳。
  var ledger: DispatchRemoteLedger { .settled(.init(repositories: ["origin": origin])) }

  func pullRequest(
    _ number: Int, head: String, repo: GitHubRepoName? = nil, reviewDecision: String? = nil
  ) -> GitHubPullRequest {
    GitHubPullRequest(
      number: number, title: "pr \(number)", headRefName: head, reviewDecision: reviewDecision,
      headRepository: repo ?? origin)
  }

  // MARK: - 相関（PR headRef → branch チップ）

  func testPullRequestBadgeCorrelatesToBranchAndWorktree() {
    let input = DispatchSectionBuilder.Input(
      worktrees: [GitWorktree(path: "/tmp/wt/feat-x", branch: "feat/x", head: "a", isMain: false)],
      remoteBranches: [
        GitBranch(name: "origin/feat/x", relativeDate: "3h前", upstream: nil)
      ],
      pullRequests: [pullRequest(42, head: "feat/x")], remoteLedger: ledger)
    let sections = DispatchSectionBuilder.build(input)
    XCTAssertEqual(
      section(sections, "Worktrees")?.items.first?.badges.map(\.text), ["#42"],
      "worktree の branch が open PR に一致 → #42 チップ")
    XCTAssertEqual(
      section(sections, "Remote branches")?.items.first?.badges.map(\.text), ["#42"],
      "remote の local 部分が open PR に一致 → #42 チップ")
  }

  /// open PR に head 一致する worktree/local/remote 行は linkedPRNumber を焼き、バッジと一致する。
  /// 一致しない行は linkedPRNumber==nil かつバッジ無し（バッジ＝開ける の SSOT 検証）。
  func testLinkedPRNumberMatchesBadgeAndIsNilWhenUnlinked() {
    let input = DispatchSectionBuilder.Input(
      worktrees: [
        GitWorktree(path: "/tmp/wt/feat-wt", branch: "feat/wt", head: "a", isMain: false),
        GitWorktree(path: "/tmp/wt/plain", branch: "plain", head: "b", isMain: false),
      ],
      localBranches: [
        GitBranch(name: "feat/local", relativeDate: "1d前", upstream: nil),
        GitBranch(name: "chore/y", relativeDate: "2d前", upstream: nil),
      ],
      remoteBranches: [
        GitBranch(
          name: "origin/feat/remote", relativeDate: "3h前", upstream: nil),
        GitBranch(name: "origin/nope/z", relativeDate: "4h前", upstream: nil),
      ],
      pullRequests: [
        pullRequest(42, head: "feat/wt"), pullRequest(43, head: "feat/local"),
        pullRequest(44, head: "feat/remote"),
      ], remoteLedger: ledger)
    let sections = DispatchSectionBuilder.build(input)

    func item(_ title: String, _ name: String) -> DispatchItem? {
      section(sections, title)?.items.first { $0.name == name }
    }

    for (title, name, number) in [
      ("Worktrees", "feat-wt", 42), ("Local branches", "feat/local", 43),
      ("Remote branches", "origin/feat/remote", 44),
    ] {
      let it = item(title, name)
      XCTAssertEqual(it?.linkedPRNumber, number, "\(title) の \(name) は PR #\(number) に紐づく")
      XCTAssertEqual(
        it?.badges.map(\.text), ["#\(number)"], "\(title) の \(name) のバッジは #\(number)（番号と一致）")
    }

    for (title, name) in [
      ("Worktrees", "plain"), ("Local branches", "chore/y"),
      ("Remote branches", "origin/nope/z"),
    ] {
      let it = item(title, name)
      XCTAssertNil(it?.linkedPRNumber, "\(title) の \(name) は PR に紐づかない")
      XCTAssertTrue(it?.badges.isEmpty ?? false, "\(title) の \(name) にバッジは出ない")
    }
  }

  // MARK: - 同期ピル

  /// Local branch 行の同期は **origin を追跡し・着地後・差がある**行にだけ乗る。`[gone]`・同期済み・
  /// 他 remote の upstream・着地前は無印。
  func testLocalBranchSyncRequiresOriginUpstreamAndLanding() {
    func upstream(_ remote: String, _ track: GitUpstreamTrack?) -> GitUpstream {
      GitUpstream(
        short: "\(remote)/x", ref: "refs/remotes/\(remote)/x", remote: remote,
        remoteRef: "refs/heads/x", track: track)
    }
    let branches = [
      GitBranch(
        name: "behind", relativeDate: "1d",
        upstream: upstream("origin", .counts(ahead: 0, behind: 3))),
      GitBranch(
        name: "diverged", relativeDate: "1d",
        upstream: upstream("origin", .counts(ahead: 1, behind: 2))),
      GitBranch(
        name: "synced", relativeDate: "1d", upstream: upstream("origin", nil)),
      GitBranch(
        name: "gone", relativeDate: "1d", upstream: upstream("origin", .gone)),
      GitBranch(
        name: "fork", relativeDate: "1d", upstream: upstream("fork", .counts(ahead: 0, behind: 3))),
      GitBranch(name: "local", relativeDate: "1d", upstream: nil),
    ]
    var input = DispatchSectionBuilder.Input(localBranches: branches)
    XCTAssertEqual(
      section(DispatchSectionBuilder.build(input), "Local branches")?.items.compactMap(\.sync),
      [], "着地前は全行無印")

    input.remoteFetchLanded = true
    let items = section(DispatchSectionBuilder.build(input), "Local branches")?.items ?? []
    let synced = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.sync) })
    XCTAssertEqual(synced["behind"]??.behind, 3)
    XCTAssertEqual(synced["behind"]??.isFastForwardable, true)
    XCTAssertEqual(synced["diverged"]??.ahead, 1)
    XCTAssertEqual(synced["diverged"]??.isFastForwardable, false)
    XCTAssertNil(synced["synced"] ?? nil, "同期済みは無印")
    XCTAssertNil(synced["gone"] ?? nil, "[gone] は差の数を持たない")
    XCTAssertNil(synced["fork"] ?? nil, "信頼しない remote の upstream は無印")
    XCTAssertNil(synced["local"] ?? nil)
  }

  // MARK: - 重複排除

  func testLocalBranchWithWorktreeIsExcluded() {
    let input = DispatchSectionBuilder.Input(
      worktrees: [GitWorktree(path: "/tmp/wt/main", branch: "main", head: "a", isMain: true)],
      localBranches: [
        GitBranch(name: "main", relativeDate: "1d前", upstream: nil),
        GitBranch(name: "feature", relativeDate: "2d前", upstream: nil),
      ])
    let sections = DispatchSectionBuilder.build(input)
    XCTAssertEqual(
      section(sections, "Local branches")?.items.map(\.name), ["feature"],
      "worktree を持つ main は Local branches から除外（Worktrees に出る）")
  }

  func testRemoteBranchTrackedLocallyIsExcluded() {
    let input = DispatchSectionBuilder.Input(
      localBranches: [
        GitBranch(name: "feat/x", relativeDate: "1d前", upstream: nil)
      ],
      remoteBranches: [
        GitBranch(name: "origin/feat/x", relativeDate: "3h前", upstream: nil),
        GitBranch(name: "origin/feat/y", relativeDate: "4h前", upstream: nil),
      ])
    let sections = DispatchSectionBuilder.build(input)
    XCTAssertEqual(
      section(sections, "Remote branches")?.items.map(\.name), ["origin/feat/y"],
      "ローカル追跡済みの origin/feat/x は出さない")
  }

  func testRemoteBranchReusesExistingWorktree() {
    let input = DispatchSectionBuilder.Input(
      worktrees: [GitWorktree(path: "/tmp/wt/feat-y", branch: "feat/y", head: "a", isMain: false)],
      remoteBranches: [
        GitBranch(name: "origin/feat/y", relativeDate: "4h前", upstream: nil)
      ])
    let sections = DispatchSectionBuilder.build(input)
    XCTAssertEqual(
      section(sections, "Remote branches")?.items.first?.action,
      .open(.remoteBranch(name: "origin/feat/y", existingWorktree: "/tmp/wt/feat-y")),
      "対応ローカル worktree があれば action に焼き込み再利用させる")
  }

  // MARK: - Issue 経路の対称化（既存 worktree／既存ブランチ／新規の 3 状態）

  /// Issue の 3 状態で action と文言（trailingNote/footer）が実解決に対称一致することを検証する。
  private func issueItem(worktrees: [GitWorktree], localBranches: [GitBranch]) -> DispatchItem? {
    let input = DispatchSectionBuilder.Input(
      worktrees: worktrees, localBranches: localBranches,
      issues: [GitHubIssue(number: 44, title: "bug")], githubState: .ready)
    return section(DispatchSectionBuilder.build(input), "Issues")?.items.first
  }

  func testIssueNewWorktreeWhenNoExisting() {
    let it = issueItem(worktrees: [], localBranches: [])
    XCTAssertEqual(
      it?.action, .open(.issue(number: 44, existingWorktree: nil, existingBranch: false)),
      "既存 worktree もブランチも無ければ新規作成パスを焼く")
    XCTAssertEqual(it?.enterNote, .worktree(.new))
    XCTAssertEqual(it?.footer, .launch(target: "#44", kind: .new))
  }

  func testIssueReusesExistingWorktree() {
    let it = issueItem(
      worktrees: [
        GitWorktree(path: "/tmp/wt/issue-44", branch: "issue/44", head: "a", isMain: false)
      ],
      localBranches: [
        GitBranch(
          name: "issue/44", relativeDate: "1d前", upstream: nil)
      ])
    XCTAssertEqual(
      it?.action,
      .open(.issue(number: 44, existingWorktree: "/tmp/wt/issue-44", existingBranch: true)),
      "既存 worktree があれば再利用パスを焼く（既存ブランチより優先）")
    XCTAssertEqual(it?.enterNote, .worktree(.existing))
    XCTAssertEqual(it?.footer, .launch(target: "#44", kind: .existing))
  }

  func testIssueUsesExistingBranchWhenNoWorktree() {
    let it = issueItem(
      worktrees: [],
      localBranches: [
        GitBranch(name: "issue/44", relativeDate: "1d前", upstream: nil)
      ])
    XCTAssertEqual(
      it?.action, .open(.issue(number: 44, existingWorktree: nil, existingBranch: true)),
      "worktree は無いがブランチだけ既存 → -b 無しで既存ブランチから追加")
    XCTAssertEqual(it?.enterNote, .worktree(.checkout))
    XCTAssertEqual(it?.footer, .launch(target: "#44", kind: .checkout))
  }

  // MARK: - フォールバック（GitHub 3 分岐）

  func testNotGitHubHidesIssueAndPRSections() {
    let input = DispatchSectionBuilder.Input(
      worktrees: [GitWorktree(path: "/tmp/wt/a", branch: "a", head: "x", isMain: true)],
      githubState: .notGitHub)
    let sections = DispatchSectionBuilder.build(input)
    XCTAssertNil(section(sections, "Issues"))
    XCTAssertNil(section(sections, "Pull requests"))
  }

  func testGhMissingShowsSingleInfoRow() {
    let input = DispatchSectionBuilder.Input(githubState: .ghMissing)
    let sections = DispatchSectionBuilder.build(input)
    let issues = section(sections, "Issues")
    XCTAssertEqual(issues?.items.count, 1)
    XCTAssertEqual(issues?.items.first?.isInteractive, false, "誘導情報行は選択・実行の対象外")
    XCTAssertNil(section(sections, "Pull requests"), "誘導情報行は 1 本（PR 側には出さない）")
  }

  func testLoadingShowsLoadingRow() {
    let input = DispatchSectionBuilder.Input(
      githubState: .ready, issuesFetching: true, pullRequestsFetching: true)
    let sections = DispatchSectionBuilder.build(input)
    XCTAssertEqual(section(sections, "Issues")?.items.first?.isLoadingRow, true)
    XCTAssertEqual(section(sections, "Pull requests")?.items.first?.isLoadingRow, true)
  }

  func testReadyButEmptyHidesSections() {
    let input = DispatchSectionBuilder.Input(githubState: .ready, remoteLedger: ledger)
    let sections = DispatchSectionBuilder.build(input)
    XCTAssertNil(section(sections, "Issues"), "ready でも 0 件のセクションは消える")
    XCTAssertNil(section(sections, "Pull requests"))
  }

  func testEmptyWorktreesHidesSection() {
    let sections = DispatchSectionBuilder.build(DispatchSectionBuilder.Input(githubState: .ready))
    XCTAssertNil(section(sections, "Worktrees"))
  }

  // MARK: - action ペイロード

  func testActionPayloads() {
    let input = DispatchSectionBuilder.Input(
      issues: [GitHubIssue(number: 7, title: "bug")],
      pullRequests: [
        pullRequest(
          9, head: "fork/x", repo: GitHubRepoName(nameWithOwner: "someone/r"),
          reviewDecision: "REVIEW_REQUIRED")
      ],
      githubState: .ready, remoteLedger: ledger)
    let sections = DispatchSectionBuilder.build(input)
    XCTAssertEqual(
      section(sections, "Issues")?.items.first?.action,
      .open(.issue(number: 7, existingWorktree: nil, existingBranch: false)))
    let pr = section(sections, "Pull requests")?.items.first
    XCTAssertEqual(pr?.action, .pullRequest(number: 9, open: nil), "他人の fork の PR はブラウザで開く")
    XCTAssertEqual(pr?.enterNote, .browser)
    XCTAssertEqual(pr?.footer, .browse(target: "#9"))
    XCTAssertEqual(pr?.reviewNote, .reviewRequired, "REVIEW_REQUIRED → reviewRequired")
  }
}
