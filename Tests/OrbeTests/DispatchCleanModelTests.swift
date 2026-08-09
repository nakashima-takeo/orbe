import XCTest

@testable import Orbe

/// clean 画面の状態と操作（`DispatchCleanModel`）。キーの意味はモデルが持つのでモデルを直接叩く。
@MainActor
final class DispatchCleanModelTests: OrbeTestCase {

  /// safe 2 行・caution 1 行・inUse 1 行の凍結スナップショット。
  private func makeModel() -> DispatchCleanModel {
    let model = DispatchCleanModel()
    model.enter(
      rows: DispatchWorktreeClassifier.classify([
        DispatchCleanFacts(path: "/wt/safe-a", branch: "feat/a", isGone: true, unmergedCommits: 0),
        DispatchCleanFacts(path: "/wt/safe-b", branch: "feat/b", isPrunable: true),
        DispatchCleanFacts(path: "/wt/caution", branch: "feat/c", isGone: true, unmergedCommits: 6),
        DispatchCleanFacts(path: "/repo", branch: "main", isMain: true),
      ]))
    return model
  }

  func testInitialState() {
    let m = makeModel()
    XCTAssertEqual(m.rows.map(\.name), ["safe-a", "safe-b", "caution", "repo"])
    XCTAssertEqual(m.selectableRows.map(\.name), ["safe-a", "safe-b", "caution"], "inUse は対象外")
    XCTAssertEqual(m.state(of: m.rows[0]), .worktreeOnly, "safe 群は全チェック済みで開く")
    XCTAssertEqual(m.state(of: m.rows[1]), .worktreeOnly)
    XCTAssertEqual(m.state(of: m.rows[2]), .none, "caution 行は未選択")
    XCTAssertEqual(m.cursor, 0, "カーソルは選択可能行の先頭")
    XCTAssertTrue(m.deleteBranch, "ブランチ削除トグルは既定 ON")
    XCTAssertEqual(m.selectedCount, 2)
    XCTAssertTrue(m.canExecute)
  }

  func testMoveSkipsInUseAndWraps() {
    let m = makeModel()
    m.move(1)
    m.move(1)
    XCTAssertEqual(m.cursorRow?.name, "caution")
    m.move(1)
    XCTAssertEqual(m.cursorRow?.name, "safe-a", "inUse を飛ばして先頭へ wrap")
    m.move(-1)
    XCTAssertEqual(m.cursorRow?.name, "caution", "先頭で上 → 末尾へ wrap")
  }

  /// safe 行は 2 状態で巡回する（ブランチを消すかはフッタのトグルが決める）。
  func testSafeRowCyclesTwoStates() {
    let m = makeModel()
    m.advance()
    XCTAssertEqual(m.state(of: m.rows[0]), .none)
    m.advance()
    XCTAssertEqual(m.state(of: m.rows[0]), .worktreeOnly)
  }

  /// caution 行は 3 状態で巡回する（空 → worktree のみ → worktree + ブランチ → 空）。
  func testCautionRowCyclesThreeStates() {
    let m = makeModel()
    let caution = m.rows[2]
    m.advance(at: caution.id)
    XCTAssertEqual(m.state(of: caution), .worktreeOnly)
    m.advance()
    XCTAssertEqual(m.state(of: caution), .worktreeAndBranch)
    m.advance()
    XCTAssertEqual(m.state(of: caution), .none)
  }

  /// 行クリックはカーソルもその行へ移す（次に space/⏎ が効く行がハイライトと一致する）。
  func testAdvanceAtMovesCursor() {
    let m = makeModel()
    m.advance(at: m.rows[2].id)
    XCTAssertEqual(m.cursor, 2)
    XCTAssertEqual(m.cursorRow?.name, "caution")
  }

  /// `a` は追加のみ。既に付いている状態を落とさず、caution 行にも効かない。
  func testSelectAllSafeIsAdditiveOnly() {
    let m = makeModel()
    m.advance()  // safe-a を外す
    m.advance(at: m.rows[2].id)
    m.advance()  // caution を worktree + ブランチ へ
    m.selectAllSafe()
    XCTAssertEqual(m.state(of: m.rows[0]), .worktreeOnly, "外れていた safe 行が付く")
    XCTAssertEqual(m.state(of: m.rows[1]), .worktreeOnly, "付いていた safe 行はそのまま")
    XCTAssertEqual(m.state(of: m.rows[2]), .worktreeAndBranch, "caution 行には効かない")
  }

  /// `worktree + ブランチ` も 1 件として数える。
  func testSelectedCountCountsBothSelections() {
    let m = makeModel()
    m.advance(at: m.rows[2].id)
    m.advance()
    XCTAssertEqual(m.state(of: m.rows[2]), .worktreeAndBranch)
    XCTAssertEqual(m.selectedCount, 3)
  }

  func testCannotExecuteWithNothingSelected() {
    let m = makeModel()
    m.advance()
    m.move(1)
    m.advance()
    XCTAssertEqual(m.selectedCount, 0)
    XCTAssertFalse(m.canExecute)
  }

  func testCannotExecuteWhileDeleting() {
    let m = makeModel()
    m.isDeleting = true
    XCTAssertFalse(m.canExecute)
  }

  /// ブランチを消すかは safe 行はトグル・caution 行は行ごとの状態が決める。
  func testDeletesBranchSplitsSafeAndCaution() {
    let m = makeModel()
    XCTAssertTrue(m.deletesBranch(m.rows[0]), "safe 行はトグル（既定 ON）に従う")
    m.deleteBranch = false
    XCTAssertFalse(m.deletesBranch(m.rows[0]))

    let caution = m.rows[2]
    XCTAssertFalse(m.deletesBranch(caution), "未選択の caution 行は消さない")
    m.advance(at: caution.id)
    XCTAssertFalse(m.deletesBranch(caution), "`worktree のみ` では消さない")
    m.advance()
    XCTAssertTrue(m.deletesBranch(caution), "`worktree + ブランチ` を選んだ行だけ消す")
  }

  func testRequestsCarryPerRowBranchDecision() {
    let m = makeModel()
    m.deleteBranch = false
    m.advance(at: m.rows[2].id)
    m.advance()  // caution を worktree + ブランチ へ
    XCTAssertEqual(
      m.requests(),
      [
        CleanDeleteRequest(path: "/wt/safe-a", branch: "feat/a", deleteBranch: false),
        CleanDeleteRequest(path: "/wt/safe-b", branch: "feat/b", deleteBranch: false),
        CleanDeleteRequest(path: "/wt/caution", branch: "feat/c", deleteBranch: true),
      ])
  }

  /// 一部失敗の後は成功行が消え、選択は全解除、カーソルは範囲内へ。分類はやり直さない。
  func testPartialFailureRemovesSucceededRowsAndClearsSelection() {
    let m = makeModel()
    m.isDeleting = true
    m.applyPartialFailure(succeededPaths: ["/wt/safe-a", "/wt/safe-b"], message: "3 件中 1 件失敗")
    XCTAssertEqual(m.rows.map(\.name), ["caution", "repo"])
    XCTAssertEqual(m.selectedCount, 0)
    XCTAssertEqual(m.cursor, 0)
    XCTAssertFalse(m.isDeleting)
    XCTAssertEqual(m.errorMessage, "3 件中 1 件失敗")
  }
}
