import XCTest

@testable import Orbe

/// ブランチ名指しの PR 取得（`--state all --head <branch>`）と行の突き合わせ（`rows` の配線）。
/// 一覧の窓（直近 N 件）を使わないので、PR の古さは事実の見え方に影響しない——open は安全確認、
/// closed はチップと推定に、どちらも名指し結果から決まる。
extension DispatchWorktreeClassifierTests {

  /// open PR は名指し結果から立ち、安全確認を落とす（窓落ちで素通りしない）。
  func testOpenPRFromNamedFetchBlocksSafety() {
    let r = branchPRRow([pr(139, "OPEN")])
    XCTAssertEqual(r.group, .caution, "レビュー中のブランチは安全群に入れない")
    XCTAssertEqual(r.chips.first, .openPR(139))
  }

  /// merged PR は名指し結果からチップ（マージ先つき）と推定に写る。
  func testMergedPRFromNamedFetchRaisesChipWithItsBase() {
    let r = branchPRRow([pr(113, "MERGED", base: "develop")], containment: .patchEquivalent)
    XCTAssertEqual(r.group, .safe)
    XCTAssertTrue(r.chips.contains(.mergedPR(113, base: "develop")))
  }

  /// **fork（cross-repo）の PR はこのブランチの事実ではない。** `--head` はブランチ名でしか
  /// 絞れないため他人の fork の同名ブランチの PR も返るが、レビュー中でも行を塞がない。
  func testCrossRepoOpenPRDoesNotBlockSafety() {
    let r = branchPRRow([pr(999, "OPEN", cross: true)], containment: .patchEquivalent)
    XCTAssertEqual(r.group, .safe, "他人の fork のレビューはこのブランチの安全確認と無関係")
    XCTAssertFalse(r.vocabulary.contains(.openPR(999)))
  }

  /// fork の PR を除外した後の**最新 1 件**を採る（並びは gh の作成日時降順のまま）。
  func testCrossRepoPRsAreExcludedBeforePickingTheLatest() {
    let r = branchPRRow(
      [pr(999, "MERGED", cross: true), pr(100, "MERGED", base: "develop")],
      containment: .patchEquivalent)
    XCTAssertTrue(r.chips.contains(.mergedPR(100, base: "develop")), "自リポジトリの PR が採られる")
    XCTAssertFalse(r.vocabulary.contains(.mergedPR(999, base: "main")), "fork の PR は事実にしない")
  }

  /// open と closed は独立に立つ（`--state all` の 1 往復が両方を運ぶ）。
  /// 再オープンや作り直しの並びでも、open は最新の OPEN・closed は最新の非 OPEN から決まる。
  func testOpenAndClosedFactsCoexistFromOneFetch() {
    let r = branchPRRow([pr(300, "OPEN"), pr(200, "MERGED", base: "develop"), pr(100, "CLOSED")])
    XCTAssertEqual(r.group, .caution, "open PR が居る限り安全群に入らない")
    XCTAssertEqual(r.chips.first, .openPR(300))
    XCTAssertTrue(r.vocabulary.contains(.mergedPR(200, base: "develop")), "closed 側は最新の非 OPEN")
  }

  // MARK: - ヘルパ

  private func pr(
    _ number: Int, _ state: String, base: String = "main", cross: Bool = false
  ) -> GitHubBranchPR {
    GitHubBranchPR(
      number: number, headRefName: "feat/x", state: state, baseRefName: base,
      isCrossRepository: cross)
  }

  /// `feat/x` の worktree 1 本を、名指し取得の着地とともに `rows` へ通した行。
  /// PR 以外の事実は安全確認を全部通る形（clean・操作なし・`[gone]`・取り込み済み）に固定する。
  private func branchPRRow(
    _ prs: [GitHubBranchPR], containment: GitBranchContainment? = .patchEquivalent
  ) -> CleanRow {
    let rows = DispatchWorktreeClassifier.rows(
      DispatchWorktreeClassifier.Input(
        worktrees: [
          GitWorktree(path: "/repo", branch: "main", head: "m", isMain: true),
          GitWorktree(path: "/wt/x", branch: "feat/x", head: "aaa", isMain: false),
        ],
        localBranches: [
          GitBranch(
            name: "feat/x", relativeDate: "1d", worktreePath: "/wt/x",
            upstream: "origin/feat/x", track: "[gone]")
        ],
        branchPullRequests: prs,
        probes: [
          "/wt/x": DispatchCleanProbe(
            status: GitWorktreeStatusCounts(modified: 0, untracked: 0),
            containment: containment, operation: .none)
        ],
        defaultBranchLabel: "main"))
    return rows.first { $0.name == "x" }!
  }
}
