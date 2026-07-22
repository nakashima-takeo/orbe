import XCTest

@testable import Orbe

/// DispatchSectionBuilder（純粋関数）の相関・重複排除・フォールバック・action ペイロード検証。
final class DispatchSectionBuilderTests: XCTestCase {

  private func section(_ sections: [DispatchSection], _ title: String) -> DispatchSection? {
    sections.first { $0.title == title }
  }

  // MARK: - 相関（PR headRef → branch チップ）

  func testPullRequestBadgeCorrelatesToBranchAndWorktree() {
    let input = DispatchSectionBuilder.Input(
      worktrees: [GitWorktree(path: "/tmp/wt/feat-x", branch: "feat/x", head: "a", isMain: false)],
      remoteBranches: [
        GitBranch(name: "origin/feat/x", relativeDate: "3h前", worktreePath: nil, upstream: nil)
      ],
      pullRequests: [
        GitHubPullRequest(
          number: 42, title: "feat: x", headRefName: "feat/x", reviewDecision: nil,
          isCrossRepository: false)
      ])
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
        GitBranch(name: "feat/local", relativeDate: "1d前", worktreePath: nil, upstream: nil),
        GitBranch(name: "chore/y", relativeDate: "2d前", worktreePath: nil, upstream: nil),
      ],
      remoteBranches: [
        GitBranch(
          name: "origin/feat/remote", relativeDate: "3h前", worktreePath: nil, upstream: nil),
        GitBranch(name: "origin/nope/z", relativeDate: "4h前", worktreePath: nil, upstream: nil),
      ],
      pullRequests: [
        GitHubPullRequest(
          number: 42, title: "feat: wt", headRefName: "feat/wt", reviewDecision: nil,
          isCrossRepository: false),
        GitHubPullRequest(
          number: 43, title: "feat: local", headRefName: "feat/local", reviewDecision: nil,
          isCrossRepository: false),
        GitHubPullRequest(
          number: 44, title: "feat: remote", headRefName: "feat/remote", reviewDecision: nil,
          isCrossRepository: false),
      ])
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

  // MARK: - 重複排除

  func testLocalBranchWithWorktreeIsExcluded() {
    let input = DispatchSectionBuilder.Input(
      worktrees: [GitWorktree(path: "/tmp/wt/main", branch: "main", head: "a", isMain: true)],
      localBranches: [
        GitBranch(name: "main", relativeDate: "1d前", worktreePath: "/tmp/wt/main", upstream: nil),
        GitBranch(name: "feature", relativeDate: "2d前", worktreePath: nil, upstream: nil),
      ])
    let sections = DispatchSectionBuilder.build(input)
    XCTAssertEqual(
      section(sections, "Local branches")?.items.map(\.name), ["feature"],
      "worktree を持つ main は Local branches から除外（Worktrees に出る）")
  }

  func testRemoteBranchTrackedLocallyIsExcluded() {
    let input = DispatchSectionBuilder.Input(
      localBranches: [
        GitBranch(name: "feat/x", relativeDate: "1d前", worktreePath: nil, upstream: nil)
      ],
      remoteBranches: [
        GitBranch(name: "origin/feat/x", relativeDate: "3h前", worktreePath: nil, upstream: nil),
        GitBranch(name: "origin/feat/y", relativeDate: "4h前", worktreePath: nil, upstream: nil),
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
        GitBranch(name: "origin/feat/y", relativeDate: "4h前", worktreePath: nil, upstream: nil)
      ])
    let sections = DispatchSectionBuilder.build(input)
    XCTAssertEqual(
      section(sections, "Remote branches")?.items.first?.action,
      .remoteBranch(name: "origin/feat/y", existingWorktree: "/tmp/wt/feat-y"),
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
      it?.action, .issue(number: 44, existingWorktree: nil, existingBranch: false),
      "既存 worktree もブランチも無ければ新規作成パスを焼く")
    XCTAssertEqual(it?.worktreeNote, .new)
    XCTAssertEqual(it?.footer?.kind, .new)
  }

  func testIssueReusesExistingWorktree() {
    let it = issueItem(
      worktrees: [
        GitWorktree(path: "/tmp/wt/issue-44", branch: "issue/44", head: "a", isMain: false)
      ],
      localBranches: [
        GitBranch(
          name: "issue/44", relativeDate: "1d前", worktreePath: "/tmp/wt/issue-44", upstream: nil)
      ])
    XCTAssertEqual(
      it?.action,
      .issue(number: 44, existingWorktree: "/tmp/wt/issue-44", existingBranch: true),
      "既存 worktree があれば再利用パスを焼く（既存ブランチより優先）")
    XCTAssertEqual(it?.worktreeNote, .existing)
    XCTAssertEqual(it?.footer?.kind, .existing)
  }

  func testIssueUsesExistingBranchWhenNoWorktree() {
    let it = issueItem(
      worktrees: [],
      localBranches: [
        GitBranch(name: "issue/44", relativeDate: "1d前", worktreePath: nil, upstream: nil)
      ])
    XCTAssertEqual(
      it?.action, .issue(number: 44, existingWorktree: nil, existingBranch: true),
      "worktree は無いがブランチだけ既存 → -b 無しで既存ブランチから追加")
    XCTAssertEqual(it?.worktreeNote, .checkout)
    XCTAssertEqual(it?.footer?.kind, .checkout)
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
      githubState: .ready, issuesLoading: true, pullRequestsLoading: true)
    let sections = DispatchSectionBuilder.build(input)
    XCTAssertEqual(section(sections, "Issues")?.items.first?.isLoadingRow, true)
    XCTAssertEqual(section(sections, "Pull requests")?.items.first?.isLoadingRow, true)
  }

  func testReadyButEmptyHidesSections() {
    let input = DispatchSectionBuilder.Input(githubState: .ready)
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
        GitHubPullRequest(
          number: 9, title: "pr", headRefName: "fork/x", reviewDecision: "REVIEW_REQUIRED",
          isCrossRepository: true)
      ],
      githubState: .ready)
    let sections = DispatchSectionBuilder.build(input)
    XCTAssertEqual(
      section(sections, "Issues")?.items.first?.action,
      .issue(number: 7, existingWorktree: nil, existingBranch: false))
    let pr = section(sections, "Pull requests")?.items.first
    XCTAssertEqual(
      pr?.action,
      .pullRequest(number: 9, headRef: "fork/x", isCrossRepo: true, existingWorktree: nil))
    XCTAssertEqual(pr?.reviewNote, .reviewRequired, "REVIEW_REQUIRED → reviewRequired")
  }
}
