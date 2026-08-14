import XCTest

@testable import Orbe

/// 取り込み判定（`GitBranchContainment`）由来の語彙の出し分け。**証明の種類でラベルが変わる**——
/// patch 等価と「既定ブランチが tip を含む到達性」は「merged → \<default\>」が真の主張、
/// 到達性のみは `remote に保存済み` だけを主張する（偽になり得る語は言わない）。
extension DispatchWorktreeClassifierTests {

  /// 到達性だけで安全が立った行（統合先が既定ブランチでない git-flow 等）は safe に入り、
  /// `remote に保存済み` を名乗る。**merged は名乗らない**——第0段は「単に完全 push 済みで未マージ」
  /// でも立つため、「取り込み済み」は主張として偽になり得る。
  func testReachableRowIsSafeAndClaimsSavedOnRemoteNotMerged() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/flow", branch: "feat/flow", upstream: "origin/feat/flow", track: "[gone]",
        status: clean, containment: .reachable(mergedIntoDefault: false), operation: .none))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.savedOnRemote, .gone, .branchAlsoDeleted])
    XCTAssertFalse(
      r.vocabulary.contains {
        if case .mergedIntoDefault = $0 { return true }
        return false
      }, "到達性だけの行に merged を名乗らせない")
    XCTAssertFalse(r.vocabulary.contains(.unpushed), "コミットは remote に残るので完全喪失の警告も出さない")
  }

  /// 既定ブランチが tip を含む行は、到達性の証明でも「merged → main」が真の主張なので従来どおり名乗る。
  func testReachableAncestorStillClaimsMergedIntoDefault() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/old", branch: "feat/old", upstream: "origin/feat/old", track: "[gone]",
        status: clean, containment: .reachable(mergedIntoDefault: true), operation: .none))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.mergedIntoDefault("main"), .gone, .branchAlsoDeleted])
  }

  /// merged PR チップはマージ先（gh の `baseRefName`）を運ぶ。**表示専用**で、safe の証明は
  /// `containment`（ローカル git の事実）だけが立てる——gh が届かなくても安全群入りは変わらない。
  func testMergedPRCarriesItsBaseBranch() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "big/x", upstream: "origin/big/x", track: "[gone]",
        closedPR: DispatchCleanPR(number: 123, isMerged: true, base: "develop"),
        status: clean, containment: .reachable(mergedIntoDefault: false), operation: .none))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.mergedPR(123, base: "develop"), .savedOnRemote, .branchAlsoDeleted])
  }
}
