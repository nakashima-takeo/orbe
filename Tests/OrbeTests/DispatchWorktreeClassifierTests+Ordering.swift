import XCTest

@testable import Orbe

/// 分類器の出力の**並びと件数**、および行の meta 列。群順（safe → caution → inUse）は画面の
/// 見出しの並びそのもので、`候補 N 件` バッジもここから導かれる。
extension DispatchWorktreeClassifierTests {

  func testRowsAreOrderedByGroup() {
    let rows = classify(
      DispatchCleanFacts(path: "/repo", branch: "main", isMain: true, openPR: .none),
      DispatchCleanFacts(
        path: "/wt/dirty", branch: "a", track: "[gone]",
        openPR: .none, status: GitWorktreeStatusCounts(modified: 1, untracked: 0), operation: .none),
      DispatchCleanFacts(
        path: "/wt/safe", branch: "b", track: "[gone]", openPR: .none, status: clean,
        containment: .patchEquivalent(target: "main"),
        operation: .none))
    XCTAssertEqual(rows.map(\.name), ["safe", "dirty", "repo"], "safe → caution → inUse の群順")
    XCTAssertEqual(DispatchWorktreeClassifier.candidateCount(rows), 1, "候補件数は safe 群から導く")
  }

  /// clean 画面の meta 列は**ブランチ名だけ**（パスは list モードが見せる）。
  func testMetaIsTheBranchName() {
    XCTAssertEqual(
      row(DispatchCleanFacts(path: "/wt/x", branch: "feat/x", openPR: .none)).meta, "feat/x")
    XCTAssertEqual(
      row(DispatchCleanFacts(path: "/wt/x", openPR: .none)).meta, "/wt/x", "detached はパスへ落とす")
  }
}
