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
    let r = branchPRRow(
      [pr(113, "MERGED", base: "develop")], containment: .patchEquivalent(target: "main"))
    XCTAssertEqual(r.group, .safe)
    XCTAssertTrue(r.chips.contains(.mergedPR(113, base: "develop")))
  }

  /// **fork（cross-repo）の PR はこのブランチの事実ではない。** `--head` はブランチ名でしか
  /// 絞れないため他人の fork の同名ブランチの PR も返るが、レビュー中でも行を塞がない。
  func testCrossRepoOpenPRDoesNotBlockSafety() {
    let r = branchPRRow(
      [pr(999, "OPEN", cross: true)], containment: .patchEquivalent(target: "main"))
    XCTAssertEqual(r.group, .safe, "他人の fork のレビューはこのブランチの安全確認と無関係")
    XCTAssertFalse(r.vocabulary.contains(.openPR(999)))
  }

  /// fork の PR を除外した後の**最新 1 件**を採る（並びは gh の作成日時降順のまま）。
  func testCrossRepoPRsAreExcludedBeforePickingTheLatest() {
    let r = branchPRRow(
      [pr(999, "MERGED", cross: true), pr(100, "MERGED", base: "develop")],
      containment: .patchEquivalent(target: "main"))
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

  /// **cross-repo の足切りは落とす方向にしか誤らない。** `isCrossRepository` は「head が gh の
  /// 解決した base リポジトリと別か」でしかなく、fork を clone して `upstream` を張った形では
  /// 自分の PR も真になる。そのとき失うのは推定（とチップ）だけで、行は確認群へ落ちる——
  /// 消して困るものが残る側なので、番号を騙って安全群へ押し上げることは起きない。
  func testAllCrossRepoPRsLoseTheHintInsteadOfPassingSafety() {
    let r = branchPRRow([pr(120, "MERGED", cross: true)], track: nil)
    XCTAssertEqual(r.group, .caution, "推定が 1 つも立たない行は安全群に入らない")
    XCTAssertFalse(r.vocabulary.contains(.mergedPR(120, base: "main")), "cross-repo の PR は事実にしない")
  }

  /// **行は渡された配列を鵜呑みにせず、`headRefName` で自分の事実だけを採る。**
  /// `branchPRLookup` は `rows()` と `extraContainmentTargets` の共通口で、後者には head を跨いで
  /// 平坦化した配列（`landedBranchPRs`）が渡る——この 1 点が消えると隣の head の PR が事実になる。
  func testEachRowTakesOnlyItsOwnHeadFromItsFetch() {
    let rows = DispatchWorktreeClassifier.rows(
      DispatchWorktreeClassifier.Input(
        worktrees: [
          GitWorktree(path: "/wt/x", branch: "feat/x", head: "aaa", isMain: false),
          GitWorktree(path: "/wt/y", branch: "feat/y", head: "bbb", isMain: false),
        ],
        branchPRStates: [
          // 隣の head の PR が混ざって届いても、行はそれを自分の事実にしない。
          "feat/x": .loaded([pr(10, "OPEN"), pr(20, "MERGED", base: "develop", head: "feat/y")]),
          "feat/y": .loaded([pr(20, "MERGED", base: "develop", head: "feat/y")]),
        ]))
    let x = rows.first { $0.name == "x" }!
    let y = rows.first { $0.name == "y" }!
    XCTAssertEqual(x.chips.first, .openPR(10), "feat/x は自分の open PR だけを拾う")
    XCTAssertFalse(x.vocabulary.contains(.mergedPR(20, base: "develop")), "隣の head の PR は拾わない")
    XCTAssertTrue(y.vocabulary.contains(.mergedPR(20, base: "develop")), "feat/y は自分の PR を拾う")
    XCTAssertFalse(y.vocabulary.contains(.openPR(10)), "隣の head の PR は拾わない")
  }

  // MARK: - 取得の状態（取得中／取得失敗）

  /// **取得中の head は安全群に入れない。** 他の確認が全部通っていても、「レビュー中でない」を
  /// 確かめていない以上は安全と読まない。行はチップを増やさず、行頭の回転グリフだけで語る。
  func testFetchingHeadIsNeitherSafeNorReady() {
    let r = branchPRRow(state: .fetching)
    XCTAssertEqual(r.group, .caution, "確かめていない PR 軸は安全確認を落とす")
    XCTAssertFalse(r.isReady, "揃っていない行は選べない")
    XCTAssertFalse(r.vocabulary.contains(.unverified), "取得中はチップを立てない（グリフが語る）")
  }

  /// **取得に失敗した head は「情報取得に失敗」を見せたうえで手動選択させる。**
  /// 安全とは読まない（確認群）が、行そのものは確定しているので選べる。
  func testFailedHeadFallsToCautionWithTheUnverifiedChip() {
    let r = branchPRRow(state: .failed)
    XCTAssertEqual(r.group, .caution)
    XCTAssertTrue(r.isReady, "決着はついているので手で選べる")
    XCTAssertTrue(r.vocabulary.contains(.unverified), "情報取得に失敗したことを見せる")
  }

  /// 確かめて 0 件（`.loaded([])`）なら従来どおり安全群へ入り、確定している。
  /// gh が使えないリポジトリもこの形で届く。
  func testVerifiedEmptyHeadIsSafeAndReady() {
    let r = branchPRRow()
    XCTAssertEqual(r.group, .safe)
    XCTAssertTrue(r.isReady)
    XCTAssertFalse(r.vocabulary.contains(.unverified))
  }

  /// **detached（`branch == nil`）は PR の head になり得ない**ので、PR 軸を待たない。
  func testDetachedRowNeverWaitsForThePRAxis() {
    let rows = DispatchWorktreeClassifier.rows(
      DispatchWorktreeClassifier.Input(
        worktrees: [GitWorktree(path: "/wt/d", branch: nil, head: "ccc", isMain: false)],
        probes: [
          "/wt/d": DispatchCleanProbe(
            status: GitWorktreeStatusCounts(modified: 0, untracked: 0),
            containment: .patchEquivalent(target: "main"), operation: .none)
        ]))
    XCTAssertTrue(rows[0].isReady, "確認対象が無いので待つものが無い")
  }

  /// プローブが飛んでいる間の行は、PR が確定していても選べない。
  func testProbingRowIsNotReady() {
    let r = branchPRRow(probing: true)
    XCTAssertFalse(r.isReady, "実測が未着地の行は選べない")
  }

  /// **在庫中の実測を「取得に失敗した」と読まない。** 差分発行が全量発行より先に着地した回は実測が
  /// 部分辞書で届くので、まだ返っていない行の `containment` も nil になる。そこで判定不能チップを
  /// 立てると、行頭の回転グリフ（まだ動いている）と同じ行で食い違う。
  func testProbingRowDoesNotClaimAFailedLookup() {
    let probing = branchPRRow(containment: nil, probing: true)
    XCTAssertFalse(probing.vocabulary.contains(.unverified), "着地の前に失敗を名乗らない")
    let landed = branchPRRow(containment: nil)
    XCTAssertTrue(landed.vocabulary.contains(.unverified), "着地して nil なら失敗として見せる")
  }

  /// **台帳に無い head は「まだ確かめていない」へ倒す。** ここが「確かめて 0 件」に倒れると、
  /// 取得が着地していないブランチが安全群へ入り、自動チェックまで灯る。
  func testHeadMissingFromTheLedgerFallsBackToFetching() {
    let rows = DispatchWorktreeClassifier.rows(
      DispatchWorktreeClassifier.Input(
        worktrees: [GitWorktree(path: "/wt/x", branch: "feat/x", head: "aaa", isMain: false)],
        branchPRStates: [:],
        probes: [
          "/wt/x": DispatchCleanProbe(
            status: GitWorktreeStatusCounts(modified: 0, untracked: 0),
            containment: .patchEquivalent(target: "main"), operation: .none)
        ]))
    XCTAssertEqual(rows[0].group, .caution, "台帳に無い head を確かめ済みと読まない")
    XCTAssertFalse(rows[0].isReady)
  }

  // MARK: - 追加比較先（gh ヒント → 取り込み判定の入力）

  /// merged PR の base が「`origin/<base>` がローカルに実在し既定と異なる」ときだけ比較先になる。
  /// PR の選択は `rows()` と同一規約（cross-repo 除外 → head ごとの最新の非 OPEN → MERGED のみ）。
  func testExtraContainmentTargetsFollowTheSamePRSelectionAsRows() {
    let worktrees = [
      GitWorktree(path: "/repo", branch: "main", head: "m", isMain: true),
      GitWorktree(path: "/wt/x", branch: "feat/x", head: "a", isMain: false),
      GitWorktree(path: "/wt/y", branch: "feat/y", head: "b", isMain: false),
      GitWorktree(path: "/wt/d", branch: nil, head: "c", isMain: false),
    ]
    let remotes: Set<String> = ["origin/main", "origin/develop"]

    XCTAssertEqual(
      DispatchWorktreeClassifier.extraContainmentTargets(
        worktrees: worktrees,
        branchPullRequests: [pr(1, "MERGED", base: "develop")],
        remoteBranchNames: remotes, defaultBranch: "origin/main"),
      ["/wt/x": ["origin/develop"]], "MERGED × 実在 × 非既定の base だけが比較先になる")

    XCTAssertEqual(
      DispatchWorktreeClassifier.extraContainmentTargets(
        worktrees: worktrees,
        branchPullRequests: [pr(2, "MERGED", base: "develop", cross: true)],
        remoteBranchNames: remotes, defaultBranch: "origin/main"),
      [:], "cross-repo の PR はこのブランチの事実ではない（rows() と同じ足切り）")

    XCTAssertEqual(
      DispatchWorktreeClassifier.extraContainmentTargets(
        worktrees: worktrees,
        branchPullRequests: [pr(3, "CLOSED", base: "develop"), pr(2, "MERGED", base: "develop")],
        remoteBranchNames: remotes, defaultBranch: "origin/main"),
      [:], "最新の非 OPEN が CLOSED なら base を信じない（rows() の closedPR 選択と同一）")

    XCTAssertEqual(
      DispatchWorktreeClassifier.extraContainmentTargets(
        worktrees: worktrees,
        branchPullRequests: [pr(4, "MERGED", base: "main")],
        remoteBranchNames: remotes, defaultBranch: "origin/main"),
      [:], "既定と同名の base は足さない（既定が既にリストにいる）")

    XCTAssertEqual(
      DispatchWorktreeClassifier.extraContainmentTargets(
        worktrees: worktrees,
        branchPullRequests: [pr(5, "MERGED", base: "release/1.0")],
        remoteBranchNames: remotes, defaultBranch: "origin/main"),
      [:], "origin/<base> がローカルに実在しなければ入口で落とす（証明はローカル）")

    XCTAssertEqual(
      DispatchWorktreeClassifier.extraContainmentTargets(
        worktrees: worktrees,
        branchPullRequests: [
          pr(6, "MERGED", base: "develop", head: "main"),
          pr(7, "MERGED", base: "develop", head: "feat/y"),
        ],
        remoteBranchNames: remotes, defaultBranch: "origin/main"),
      ["/wt/y": ["origin/develop"]], "main worktree と detached は対象外")
  }

  // MARK: - ヘルパ

  private func pr(
    _ number: Int, _ state: String, base: String = "main", cross: Bool = false,
    head: String = "feat/x"
  ) -> GitHubBranchPR {
    GitHubBranchPR(
      number: number, headRefName: head, state: state, baseRefName: base,
      isCrossRepository: cross)
  }

  /// `feat/x` の worktree 1 本を、名指し取得の着地とともに `rows` へ通した行。
  /// PR 以外の事実は安全確認を全部通る形（clean・操作なし・`[gone]`・取り込み済み）に固定する。
  /// `track` を nil にすると `[gone]` の推定が消え、**推定が PR だけになる**行を作れる。
  private func branchPRRow(
    _ prs: [GitHubBranchPR], containment: GitBranchContainment? = .patchEquivalent(target: "main"),
    track: String? = "[gone]"
  ) -> CleanRow {
    branchPRRow(state: .loaded(prs), containment: containment, track: track)
  }

  /// head の取得状態そのものを渡す版（取得中／取得失敗の検証はこちらを使う）。
  private func branchPRRow(
    state: BranchPRState = .loaded([]),
    containment: GitBranchContainment? = .patchEquivalent(target: "main"),
    track: String? = "[gone]", probing: Bool = false
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
            upstream: "origin/feat/x", track: track)
        ],
        branchPRStates: ["feat/x": state],
        probes: [
          "/wt/x": DispatchCleanProbe(
            status: GitWorktreeStatusCounts(modified: 0, untracked: 0),
            containment: containment, operation: .none)
        ],
        probingPaths: probing ? ["/wt/x"] : []))
    return rows.first { $0.name == "x" }!
  }
}
