import XCTest

@testable import Orbe

/// 取り込み判定（`GitBranchContainment`）由来の語彙の出し分け。**証明の種類でラベルが変わる**——
/// patch 等価と「tip を含む比較先のある到達性」は「merged → \<実マージ先\>」が真の主張、
/// 到達性のみは `リモート反映済み` だけを主張する（偽になり得る語は言わない）。
extension DispatchWorktreeClassifierTests {

  /// 到達性だけで安全が立った行（統合先が既定ブランチでない git-flow 等）は safe に入り、
  /// `リモート反映済み` を名乗る。**merged は名乗らない**——第0段は「単に完全 push 済みで未マージ」
  /// でも立つため、「取り込み済み」は主張として偽になり得る。
  func testReachableRowIsSafeAndClaimsOnRemoteNotMerged() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/flow", branch: "feat/flow", upstream: "origin/feat/flow", track: "[gone]",
        openPR: .none, status: clean, containment: .reachable(mergedInto: nil), operation: .none))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.onRemote, .gone])
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
        openPR: .none, status: clean, containment: .reachable(mergedInto: "main"), operation: .none)
    )
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.mergedInto("main"), .gone])
  }

  /// merged PR チップはマージ先（gh の `baseRefName`）を運ぶ。**表示専用**で、safe の証明は
  /// `containment`（ローカル git の事実）だけが立てる——gh が届かなくても安全群入りは変わらない。
  ///
  /// merged PR チップが立つ行では `リモート反映済み` は立たない——マージ済みなら remote に在ることは
  /// 含意されるので、含意される語を重ねない。空いた枠は次の事実（`[gone]`）が埋める。
  func testMergedPRCarriesItsBaseBranch() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "big/x", upstream: "origin/big/x", track: "[gone]",
        closedPR: DispatchCleanPR(number: 123, isMerged: true, base: "develop"),
        openPR: .none, status: clean, containment: .reachable(mergedInto: nil), operation: .none))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.mergedPR(123, base: "develop"), .gone])
    XCTAssertFalse(r.vocabulary.contains(.onRemote))
    XCTAssertEqual(r.overflowNotes, [])
  }

  /// 降ろすのは重複する `merged → <X>` だけ——`PR #N merged → base` と同じ「merged」を 2 枚
  /// 並べない。空いた枠は次の事実（`[gone]`）が埋める。safe 行のサブラインは開かないので降りた語は
  /// 台帳に残るだけだが、同じ主張を PR チップが可視のまま引き受けるので読める根拠は減らない。
  func testMergedPRDemotesOnlyTheDuplicateMergedInto() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "big/x", upstream: "origin/big/x", track: "[gone]",
        closedPR: DispatchCleanPR(number: 123, isMerged: true, base: "develop"),
        openPR: .none, status: clean, containment: .patchEquivalent(target: "origin/develop"),
        operation: .none))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.mergedPR(123, base: "develop"), .gone])
    XCTAssertEqual(r.overflowNotes, [.mergedInto("develop")], "降りた証明ピルは受け皿に残る")
  }

  /// `merged → <X>` は verdict が運ぶ実マージ先を名乗り、表示では先頭の `origin/` を剥がす
  /// （比較先は `origin/develop` のような remote 追跡名で渡る事実そのもの）。
  func testMergedIntoLabelStripsTheRemotePrefix() {
    let patch = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", openPR: .none, status: clean,
        containment: .patchEquivalent(target: "origin/develop"), operation: .none))
    XCTAssertTrue(patch.vocabulary.contains(.mergedInto("develop")))

    let reachable = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", openPR: .none, status: clean,
        containment: .reachable(mergedInto: "origin/develop"), operation: .none))
    XCTAssertTrue(reachable.vocabulary.contains(.mergedInto("develop")))
  }

  /// `リモート反映済み` が立つのは「remote 上にコミットが存在する」という 1 つの事実で、
  /// 到達性の証明（`.reachable(mergedInto: nil)`）と upstream 一致（track が空）のどちらからでも立つ。
  /// **マージ済みの行では立たない**——マージされていれば remote に在ることは含意される。
  func testOnRemoteStandsOnEitherProofAndYieldsToMerged() {
    let synced = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", openPR: .none, status: clean,
        containment: nil, operation: .none))
    XCTAssertEqual(
      synced.vocabulary.filter { $0 == .onRemote }, [.onRemote], "upstream 一致だけでも 1 枚立つ")

    let reachable = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", track: "[gone]",
        openPR: .none, status: clean, containment: .reachable(mergedInto: nil), operation: .none))
    XCTAssertEqual(
      reachable.vocabulary.filter { $0 == .onRemote }, [.onRemote], "到達性だけでも 1 枚立つ")

    let both = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", openPR: .none, status: clean,
        containment: .reachable(mergedInto: nil), operation: .none))
    XCTAssertEqual(
      both.vocabulary.filter { $0 == .onRemote }, [.onRemote], "両方立っても重ならない")

    let merged = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", openPR: .none, status: clean,
        containment: .reachable(mergedInto: "main"), operation: .none))
    XCTAssertEqual(merged.chips, [.mergedInto("main")])
    XCTAssertFalse(merged.vocabulary.contains(.onRemote), "マージが含意する語は重ねない")

    let mergedPR = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x",
        closedPR: DispatchCleanPR(number: 142, isMerged: true, base: "main"), openPR: .none,
        status: clean, containment: nil, operation: .none))
    XCTAssertFalse(mergedPR.vocabulary.contains(.onRemote), "PR merged の行でも重ねない")
  }

  // MARK: - 判定不能チップ

  /// 安全確認に使う事実（status／停止中の git 操作／取り込み判定）のどれかを確かめられなかった
  /// 確認行に立つ。分類（群の振り分け）は変えない——判定不能を安全と読まない契約は分類側が既に持つ。
  func testUnverifiedChipRaisesWhenAnySafetyFactIsMissing() {
    let status = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", openPR: .none, status: nil,
        containment: .patchEquivalent(target: "main"), operation: .none))
    XCTAssertEqual(status.group, .caution)
    XCTAssertTrue(status.vocabulary.contains(.unverified))

    let operation = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", openPR: .none, status: clean,
        containment: .patchEquivalent(target: "main"), operation: .unknown))
    XCTAssertTrue(operation.vocabulary.contains(.unverified))

    let containment = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", openPR: .none, status: clean,
        containment: nil,
        operation: .none))
    XCTAssertTrue(containment.vocabulary.contains(.unverified))
  }

  /// prunable は status / 操作を意図的に問わない（失うものが無く、確認の対象ですらない）。
  /// 取り込み判定だけは問う。
  func testUnverifiedDoesNotCountTheWorkingTreeOnPrunableRows() {
    let verified = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", isPrunable: true, openPR: .open(139),
        containment: .patchEquivalent(target: "main")))
    XCTAssertEqual(verified.group, .caution, "open PR が安全群入りを塞ぐ")
    XCTAssertFalse(
      verified.vocabulary.contains(.unverified), "status nil・操作 unknown でも prunable は数えない")

    let missing = row(
      DispatchCleanFacts(path: "/wt/x", branch: "feat/x", isPrunable: true, openPR: .open(139)))
    XCTAssertTrue(missing.vocabulary.contains(.unverified), "取り込み判定の欠落だけは prunable でも立つ")
  }

  /// inUse 行には立たない（probe 自体を省く行で、確認群にいる理由の可視化という目的の外）。
  func testUnverifiedIsNotRaisedOnInUseRows() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x",
        openPR: .none, occupancy: PaneOccupancy(cwd: "/wt/x", agentState: "working")))
    XCTAssertEqual(r.group, .inUse)
    XCTAssertFalse(r.vocabulary.contains(.unverified))
  }

  /// detached × 判定不能の行はチップ 1 枚だけで語る——詳細を持たないので、他に書くことが
  /// 無ければサブラインも開かない（「書くことが無ければ開かない」の従来規則のまま）。
  func testDetachedUnverifiedRowShowsTheChipWithoutADetail() {
    let r = row(DispatchCleanFacts(path: "/wt/x", openPR: .none, status: clean, operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertNil(r.branch)
    XCTAssertEqual(r.chips, [.unverified], "立った事実はチップとして到達できる")
    XCTAssertFalse(r.canExpandSubline)
  }
}
