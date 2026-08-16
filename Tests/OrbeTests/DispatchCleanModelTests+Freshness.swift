import XCTest

@testable import Orbe

/// clean 画面の**鮮度**（`apply(rows:)`）。行ごとの準備完了が選択可否を決め、自動チェックは確定の
/// 瞬間の 1 度きり——ここが崩れると「ユーザーが外したチェックが裏の着地で復活する」「揃っていない
/// 行が選べる」という、破壊操作としては致命の形になる。
@MainActor
extension DispatchCleanModelTests {

  // MARK: - 行ごとの準備完了（裏の着地を取り込む）

  /// 未確定行は表示されるが**選べない**——巡回にも入らず、`toggle` も効かない。
  func testPendingRowsAreShownButNotSelectable() {
    let m = DispatchCleanModel()
    m.enter(rows: rows(readyPaths: []))
    XCTAssertEqual(m.rows.count, 3, "行そのものは出る")
    XCTAssertTrue(m.selectableRows.isEmpty, "揃っていない行は巡回の対象外")
    XCTAssertTrue(m.checked.isEmpty, "確定していない安全行は自動チェックされない")
    m.toggle(at: "/wt/safe-a")
    XCTAssertTrue(m.checked.isEmpty, "未確定行のタップは no-op")
    XCTAssertFalse(m.canExecute)
  }

  /// **確定した瞬間に 1 度だけ**自動チェックが灯る。安全群だけが灯り、確認群は灯らない。
  func testAutoCheckFiresOnceWhenARowSettles() {
    let m = DispatchCleanModel()
    m.enter(rows: rows(readyPaths: []))
    m.apply(rows: rows(readyPaths: ["/wt/safe-a"]))
    XCTAssertEqual(m.checked, ["/wt/safe-a"], "確定した安全行だけが灯る")
    m.apply(rows: rows(readyPaths: ["/wt/safe-a", "/wt/caution"]))
    XCTAssertEqual(m.checked, ["/wt/safe-a"], "確認群は確定しても灯らない")
  }

  /// **ユーザーが外したチェックは、裏の着地で復活しない。**
  func testLaterLandingsNeverReviveAnUncheckedRow() {
    let m = DispatchCleanModel()
    m.enter(rows: rows(readyPaths: ["/wt/safe-a"]))
    m.toggle(at: "/wt/safe-a")
    XCTAssertTrue(m.checked.isEmpty)
    m.apply(rows: rows(readyPaths: ["/wt/safe-a", "/wt/caution"]))
    XCTAssertTrue(m.checked.isEmpty, "確定済みの行のチェックは以後動かない")
  }

  /// カーソルは**行 id で**同じ worktree を指し続ける（行が増えて index がずれても動かない）。
  func testCursorFollowsTheSameWorktreeAcrossLandings() {
    let m = DispatchCleanModel()
    m.enter(rows: rows(readyPaths: ["/wt/caution"]))
    XCTAssertEqual(m.cursorRow?.id, "/wt/caution")
    m.apply(rows: rows(readyPaths: ["/wt/safe-a", "/wt/safe-b", "/wt/caution"]))
    XCTAssertEqual(m.cursorRow?.id, "/wt/caution", "前に並ぶ行が増えても指す先は変わらない")
  }

  /// 指していた行が消えたら近傍へ落ちる。消えた worktree の選択・ブランチの扱いも残らない。
  func testVanishedRowsDropTheirSelectionAndCursor() {
    let m = DispatchCleanModel()
    m.enter(rows: rows(readyPaths: ["/wt/safe-a", "/wt/safe-b", "/wt/caution"]))
    m.toggle(at: "/wt/caution")
    m.chooseBranch(.delete)
    XCTAssertEqual(m.cursorRow?.id, "/wt/caution")

    m.apply(rows: rows(readyPaths: ["/wt/safe-a"], paths: ["/wt/safe-a"]))

    XCTAssertEqual(m.rows.map(\.id), ["/wt/safe-a"])
    XCTAssertEqual(m.checked, ["/wt/safe-a"], "消えた行の選択は残らない")
    XCTAssertTrue(m.branchChoice.isEmpty, "消えた行のブランチの扱いも残らない")
    XCTAssertEqual(m.cursorRow?.id, "/wt/safe-a", "近傍へ落ちる")
  }

  /// **チェックは覚えたまま、揃っていない間は実行の対象から外れる。** その間その行は行頭が回転
  /// グリフになり、チェックが画面から見えず外す手立ても無い——数と依頼だけが数えていると、
  /// 見えないチェックのまま worktree が消える。
  func testCheckedRowLeavesTheExecutionSetWhileItIsNotReady() {
    let m = DispatchCleanModel()
    m.enter(rows: rows(readyPaths: ["/wt/safe-a"]))
    XCTAssertEqual(m.requests().map(\.path), ["/wt/safe-a"])

    m.apply(rows: rows(readyPaths: []))
    XCTAssertEqual(m.selectedCount, 0, "揃っていない行は数えない")
    XCTAssertEqual(m.branchDeleteCount, 0)
    XCTAssertTrue(m.requests().isEmpty, "⌘⏎ も撃たない")
    XCTAssertFalse(m.canExecute)
    XCTAssertTrue(m.checked.contains("/wt/safe-a"), "チェックそのものは覚えている")

    m.apply(rows: rows(readyPaths: ["/wt/safe-a"]))
    XCTAssertEqual(m.requests().map(\.path), ["/wt/safe-a"], "揃い直せばそのまま戻る")
  }

  /// **削除中・一部失敗の画面は裏の着地で組み替わらない**（実行対象は `beginRun` が確定済み）。
  func testApplyIsIgnoredOnceTheRunHasBegun() {
    let m = makeModel()
    m.beginRun(m.requests())
    m.apply(rows: [])
    XCTAssertEqual(m.rows.count, 4, "削除中の画面は据え置き")
    XCTAssertEqual(m.run?.requests.count, 2)
  }

  /// 3 行（safe 2・caution 1）を、指定した path だけ確定させて作る。
  private func rows(readyPaths: Set<String>, paths: [String]? = nil) -> [CleanRow] {
    let all = ["/wt/safe-a", "/wt/safe-b", "/wt/caution"]
    return DispatchWorktreeClassifier.classify(
      (paths ?? all).map { path in
        DispatchCleanFacts(
          path: path, branch: "feat/\((path as NSString).lastPathComponent)", head: "aaa",
          track: "[gone]", openPR: readyPaths.contains(path) ? CleanOpenPR.none : .pending,
          status: GitWorktreeStatusCounts(modified: 0, untracked: 0),
          containment: path.hasSuffix("caution")
            ? .unmerged(count: 6) : .patchEquivalent(target: "main"),
          operation: .none)
      })
  }
}
