import XCTest

@testable import Orbe

/// WorktreePaletteSectionBuilder（純粋関数）の同期ピル・重複排除・action ペイロード検証。
final class WorktreePaletteSectionBuilderTests: OrbeTestCase {

  func section(_ sections: [WorktreePaletteSection], _ title: String) -> WorktreePaletteSection? {
    sections.first { $0.title == title }
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
    var input = WorktreePaletteSectionBuilder.Input(localBranches: branches)
    XCTAssertEqual(
      section(WorktreePaletteSectionBuilder.build(input), "Local branches")?.items.compactMap(
        \.sync),
      [], "着地前は全行無印")

    input.remoteFetchLanded = true
    let items = section(WorktreePaletteSectionBuilder.build(input), "Local branches")?.items ?? []
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
    let input = WorktreePaletteSectionBuilder.Input(
      worktrees: [GitWorktree(path: "/tmp/wt/main", branch: "main", head: "a", isMain: true)],
      localBranches: [
        GitBranch(name: "main", relativeDate: "1d前", upstream: nil),
        GitBranch(name: "feature", relativeDate: "2d前", upstream: nil),
      ])
    let sections = WorktreePaletteSectionBuilder.build(input)
    XCTAssertEqual(
      section(sections, "Local branches")?.items.map(\.name), ["feature"],
      "worktree を持つ main は Local branches から除外（Worktrees に出る）")
  }

  func testRemoteBranchTrackedLocallyIsExcluded() {
    let input = WorktreePaletteSectionBuilder.Input(
      localBranches: [
        GitBranch(name: "feat/x", relativeDate: "1d前", upstream: nil)
      ],
      remoteBranches: [
        GitBranch(name: "origin/feat/x", relativeDate: "3h前", upstream: nil),
        GitBranch(name: "origin/feat/y", relativeDate: "4h前", upstream: nil),
      ])
    let sections = WorktreePaletteSectionBuilder.build(input)
    XCTAssertEqual(
      section(sections, "Remote branches")?.items.map(\.name), ["origin/feat/y"],
      "ローカル追跡済みの origin/feat/x は出さない")
  }

  func testRemoteBranchReusesExistingWorktree() {
    let input = WorktreePaletteSectionBuilder.Input(
      worktrees: [GitWorktree(path: "/tmp/wt/feat-y", branch: "feat/y", head: "a", isMain: false)],
      remoteBranches: [
        GitBranch(name: "origin/feat/y", relativeDate: "4h前", upstream: nil)
      ])
    let sections = WorktreePaletteSectionBuilder.build(input)
    XCTAssertEqual(
      section(sections, "Remote branches")?.items.first?.action,
      .open(.remoteBranch(name: "origin/feat/y", existingWorktree: "/tmp/wt/feat-y")),
      "対応ローカル worktree があれば action に焼き込み再利用させる")
  }

  func testEmptyWorktreesHidesSection() {
    let sections = WorktreePaletteSectionBuilder.build(WorktreePaletteSectionBuilder.Input())
    XCTAssertNil(section(sections, "Worktrees"))
  }

  // MARK: - action ペイロード

  func testActionPayloads() {
    let sections = WorktreePaletteSectionBuilder.build(.designSample)
    XCTAssertEqual(
      section(sections, "Worktrees")?.items.map(\.action),
      [
        .open(.worktree(path: NSHomeDirectory() + "/wt/agent-hooks")),
        .open(.worktree(path: NSHomeDirectory() + "/wt/diff-panel")), .clean,
      ])
    XCTAssertEqual(
      section(sections, "Local branches")?.items.first?.action, .open(.localBranch(name: "main")))
    XCTAssertEqual(
      section(sections, "Remote branches")?.items.first?.action,
      .open(.remoteBranch(name: "origin/feat/session-restore", existingWorktree: nil)))
  }
}
