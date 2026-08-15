import XCTest

@testable import Orbe

/// 取り込み判定（`GitBranchContainment`）由来の語彙の出し分け。**証明の種類でラベルが変わる**——
/// patch 等価と「tip を含む比較先のある到達性」は「merged → \<実マージ先\>」が真の主張、
/// 到達性のみは `remote に保存済み` だけを主張する（偽になり得る語は言わない）。
extension DispatchWorktreeClassifierTests {

  /// 到達性だけで安全が立った行（統合先が既定ブランチでない git-flow 等）は safe に入り、
  /// `remote に保存済み` を名乗る。**merged は名乗らない**——第0段は「単に完全 push 済みで未マージ」
  /// でも立つため、「取り込み済み」は主張として偽になり得る。
  func testReachableRowIsSafeAndClaimsSavedOnRemoteNotMerged() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/flow", branch: "feat/flow", upstream: "origin/feat/flow", track: "[gone]",
        status: clean, containment: .reachable(mergedInto: nil), operation: .none))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.savedOnRemote, .gone, .branchAlsoDeleted])
    XCTAssertFalse(
      r.vocabulary.contains {
        if case .mergedInto = $0 { return true }
        return false
      }, "到達性だけの行に merged を名乗らせない")
    XCTAssertFalse(r.vocabulary.contains(.unpushed), "コミットは remote に残るので完全喪失の警告も出さない")
  }

  /// 既定ブランチが tip を含む行は、到達性の証明でも「merged → main」が真の主張なので従来どおり名乗る。
  func testReachableAncestorStillClaimsMergedInto() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/old", branch: "feat/old", upstream: "origin/feat/old", track: "[gone]",
        status: clean, containment: .reachable(mergedInto: "main"), operation: .none))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.mergedInto("main"), .gone, .branchAlsoDeleted])
  }

  /// merged PR チップはマージ先（gh の `baseRefName`）を運ぶ。**表示専用**で、safe の証明は
  /// `containment`（ローカル git の事実）だけが立てる——gh が届かなくても安全群入りは変わらない。
  /// 証明由来の安全根拠ピル（ここでは `remote に保存済み`）は merged PR チップの行では
  /// ピル枠を争わずサブラインへ降り、空いた枠は次の事実（`[gone]`）が埋める。
  func testMergedPRCarriesItsBaseBranch() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "big/x", upstream: "origin/big/x", track: "[gone]",
        closedPR: DispatchCleanPR(number: 123, isMerged: true, base: "develop"),
        status: clean, containment: .reachable(mergedInto: nil), operation: .none))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.mergedPR(123, base: "develop"), .gone, .branchAlsoDeleted])
    XCTAssertEqual(r.overflowNotes, [.savedOnRemote], "降りた証明ピルは受け皿に残る")
  }

  /// `merged → <X>` は verdict が運ぶ実マージ先を名乗り、表示では先頭の `origin/` を剥がす
  /// （比較先は `origin/develop` のような remote 追跡名で渡る事実そのもの）。
  func testMergedIntoLabelStripsTheRemotePrefix() {
    let patch = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", status: clean,
        containment: .patchEquivalent(target: "origin/develop"), operation: .none))
    XCTAssertTrue(patch.vocabulary.contains(.mergedInto("develop")))

    let reachable = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", status: clean,
        containment: .reachable(mergedInto: "origin/develop"), operation: .none))
    XCTAssertTrue(reachable.vocabulary.contains(.mergedInto("develop")))
  }

  /// `remote に同期済み` が立つ行では `remote に保存済み` を名乗らない——同期済みが保存済みを
  /// 含意し、強い方の主張が同じ事実を含んで立っている（vocabulary からも消える＝サブラインにも
  /// 出さない）。`merged → <X>` はより強い別の主張なので抑制しない。
  func testRemoteSyncedSuppressesSavedOnRemote() {
    let synced = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", status: clean,
        containment: .reachable(mergedInto: nil), operation: .none))
    XCTAssertFalse(synced.vocabulary.contains(.savedOnRemote), "含意される語は台帳からも消える")
    XCTAssertTrue(synced.vocabulary.contains(.remoteSynced))

    let gone = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", track: "[gone]",
        status: clean, containment: .reachable(mergedInto: nil), operation: .none))
    XCTAssertTrue(
      gone.vocabulary.contains(.savedOnRemote), "同期済みが立たない行では従来どおり名乗る")

    let merged = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", status: clean,
        containment: .reachable(mergedInto: "main"), operation: .none))
    XCTAssertTrue(
      merged.vocabulary.contains(.mergedInto("main")), "merged はより強い別の主張なので抑制しない")
  }

  // MARK: - 判定不能チップ

  /// 安全確認に使う事実を確かめられなかった確認行に、何が取得できなかったかのフラグつきで立つ。
  /// 分類（群の振り分け）は変えない——判定不能を安全と読まない契約は分類側が既に持つ。
  func testUnverifiedChipNamesEachMissingFact() {
    let status = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", status: nil,
        containment: .patchEquivalent(target: "main"), operation: .none))
    XCTAssertEqual(status.group, .caution)
    XCTAssertTrue(
      status.vocabulary.contains(
        .unverified(status: true, operation: false, containment: false)))

    let operation = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", status: clean,
        containment: .patchEquivalent(target: "main"), operation: .unknown))
    XCTAssertTrue(
      operation.vocabulary.contains(
        .unverified(status: false, operation: true, containment: false)))

    let all = row(DispatchCleanFacts(path: "/wt/x", branch: "feat/x", track: "[gone]"))
    XCTAssertTrue(
      all.vocabulary.contains(.unverified(status: true, operation: true, containment: true)))
  }

  /// prunable は status / 操作を意図的に問わない（失うものが無く、確認の対象ですらない）。
  /// 取り込み判定だけは問う。
  func testUnverifiedDoesNotCountTheWorkingTreeOnPrunableRows() {
    let r = row(
      DispatchCleanFacts(path: "/wt/x", branch: "feat/x", isPrunable: true, openPR: 139))
    XCTAssertEqual(r.group, .caution, "open PR が安全群入りを塞ぐ")
    XCTAssertTrue(
      r.vocabulary.contains(.unverified(status: false, operation: false, containment: true)))
  }

  /// inUse 行には立たない（probe 自体を省く行で、確認群にいる理由の可視化という目的の外）。
  func testUnverifiedIsNotRaisedOnInUseRows() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x",
        occupancy: PaneOccupancy(cwd: "/wt/x", agentState: "working")))
    XCTAssertEqual(r.group, .inUse)
    XCTAssertFalse(r.hasUnverified)
  }

  /// detached × 判定不能の行もサブラインの詳細（何を取得できなかったか）へ到達できる。
  func testDetachedUnverifiedRowCanOpenItsDetail() {
    let r = row(DispatchCleanFacts(path: "/wt/x", status: clean, operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertNil(r.branch)
    XCTAssertTrue(r.hasUnverified)
    XCTAssertTrue(r.canExpandSubline, "ブランチも損失も無くても、判定不能の詳細があるなら開く")
  }
}
