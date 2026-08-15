import XCTest

@testable import Orbe

/// clean 画面の状態と操作（`DispatchCleanModel`）。キーの意味はモデルが持つのでモデルを直接叩く。
@MainActor
final class DispatchCleanModelTests: OrbeTestCase {

  /// safe 2 行（うち 1 行は prunable）・caution 1 行・inUse 1 行の凍結スナップショット。
  private func makeModel() -> DispatchCleanModel {
    let model = DispatchCleanModel()
    model.enter(rows: makeRows())
    return model
  }

  private func makeRows() -> [CleanRow] {
    DispatchWorktreeClassifier.classify(
      [
        DispatchCleanFacts(
          path: "/wt/safe-a", branch: "feat/a", head: "aaa", track: "[gone]",
          status: GitWorktreeStatusCounts(modified: 0, untracked: 0), containment: .patchEquivalent,
          operation: .none),
        DispatchCleanFacts(
          path: "/wt/safe-b", branch: "feat/b", head: "bbb", isPrunable: true, track: "[gone]",
          containment: .patchEquivalent),
        DispatchCleanFacts(
          path: "/wt/caution", branch: "feat/c", head: "ccc", track: "[gone]",
          status: GitWorktreeStatusCounts(modified: 0, untracked: 0),
          containment: .unmerged(count: 6),
          operation: .none),
        DispatchCleanFacts(path: "/repo", branch: "main", head: "ddd", isMain: true),
      ], defaultBranchLabel: "main")
  }

  func testInitialState() {
    let m = makeModel()
    XCTAssertEqual(m.rows.map(\.name), ["safe-a", "safe-b", "caution", "repo"])
    XCTAssertEqual(m.selectableRows.map(\.name), ["safe-a", "safe-b", "caution"], "inUse は対象外")
    XCTAssertTrue(m.isChecked(m.rows[0]), "安全群は全チェック済みで開く")
    XCTAssertTrue(m.isChecked(m.rows[1]))
    XCTAssertFalse(m.isChecked(m.rows[2]), "確認行は未選択")
    XCTAssertEqual(m.branchChoice(of: m.rows[2]), .keep, "ブランチの扱いの既定は残す")
    XCTAssertEqual(m.cursor, 0, "カーソルは選択可能行の先頭")
    XCTAssertEqual(m.phase, .selecting)
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

  /// チェックは 2 値。ブランチの扱いは別の軸なので巡回に混ざらない。
  func testCheckIsTwoValued() {
    let m = makeModel()
    m.toggleAtCursor()
    XCTAssertFalse(m.isChecked(m.rows[0]))
    m.toggleAtCursor()
    XCTAssertTrue(m.isChecked(m.rows[0]))
  }

  /// 確認行はチェックした瞬間にサブラインが開き、ブランチの扱いは `残す` で始まる。
  func testCheckOpensSublineAndDefaultsToKeep() {
    let m = makeModel()
    let caution = m.rows[2]
    XCTAssertFalse(m.isExpanded(caution), "未選択では開かない")
    m.toggle(at: caution.id)
    XCTAssertTrue(m.isExpanded(caution))
    XCTAssertEqual(m.branchChoice(of: caution), .keep)
    XCTAssertFalse(m.isExpanded(m.rows[0]), "安全行はチェック済みでも開かない")
  }

  /// ブランチを持たない行（detached）には開くものが無い。
  func testDetachedRowNeverExpands() {
    let m = DispatchCleanModel()
    m.enter(
      rows: DispatchWorktreeClassifier.classify(
        [DispatchCleanFacts(path: "/wt/detached", head: "eee")], defaultBranchLabel: "main"))
    m.toggleAtCursor()
    XCTAssertTrue(m.isChecked(m.rows[0]))
    XCTAssertFalse(m.isExpanded(m.rows[0]))
  }

  /// ←→ は**サブラインが開いている行だけ**で効く（開いていない行に不可視の状態を持たせない）。
  func testArrowsChooseBranchOnlyWhileExpanded() {
    let m = makeModel()
    let caution = m.rows[2]
    m.move(2)
    m.chooseBranch(.delete)
    XCTAssertEqual(m.branchChoice(of: caution), .keep, "閉じている行には効かない")
    m.toggleAtCursor()
    m.chooseBranch(.delete)
    XCTAssertEqual(m.branchChoice(of: caution), .delete)
    m.chooseBranch(.keep)
    XCTAssertEqual(m.branchChoice(of: caution), .keep)
  }

  /// 行クリックはカーソルもその行へ移す（次に space/⏎ が効く行がハイライトと一致する）。
  func testToggleAtMovesCursor() {
    let m = makeModel()
    m.toggle(at: m.rows[2].id)
    XCTAssertEqual(m.cursor, 2)
    XCTAssertEqual(m.cursorRow?.name, "caution")
  }

  /// `a` は追加のみ。既に付いているチェックも、確認行のブランチの扱いも落とさない。
  func testSelectAllSafeIsAdditiveOnly() {
    let m = makeModel()
    m.toggleAtCursor()  // safe-a を外す
    m.toggle(at: m.rows[2].id)
    m.chooseBranch(.delete)
    m.selectAllSafe()
    XCTAssertTrue(m.isChecked(m.rows[0]), "外れていた安全行が付く")
    XCTAssertTrue(m.isChecked(m.rows[1]), "付いていた安全行はそのまま")
    XCTAssertTrue(m.isChecked(m.rows[2]), "確認行のチェックも落とさない")
    XCTAssertEqual(m.branchChoice(of: m.rows[2]), .delete, "ブランチの扱いにも触らない")
  }

  func testSelectedCountCountsCheckedRows() {
    let m = makeModel()
    m.toggle(at: m.rows[2].id)
    XCTAssertEqual(m.selectedCount, 3)
  }

  func testCannotExecuteWithNothingSelected() {
    let m = makeModel()
    m.toggleAtCursor()
    m.move(1)
    m.toggleAtCursor()
    XCTAssertEqual(m.selectedCount, 0)
    XCTAssertFalse(m.canExecute)
  }

  func testCannotExecuteWhileDeleting() {
    let m = makeModel()
    m.beginRun(m.requests())
    XCTAssertEqual(m.phase, .deleting)
    XCTAssertFalse(m.canExecute)
  }

  /// 安全行は行内注記が出る行だけがブランチを消し、**実体の無い prunable 行はブランチに触らない**。
  /// 確認行はサブラインで選んだ 2 値がそのまま決める。
  func testDeletesBranchSplitsSafeAndCaution() {
    let m = makeModel()
    XCTAssertTrue(m.rows[0].deletesBranchImplicitly)
    XCTAssertTrue(m.deletesBranch(m.rows[0]), "安全行は無条件にブランチも消す")
    XCTAssertFalse(m.rows[1].deletesBranchImplicitly, "prunable 行は消えるのが登録だけ")
    XCTAssertFalse(m.deletesBranch(m.rows[1]))
    XCTAssertTrue(
      m.rows[0].chips.contains(.branchAlsoDeleted), "ブランチも消える行だけが行内注記を持つ")
    XCTAssertFalse(m.rows[1].chips.contains(.branchAlsoDeleted))

    let caution = m.rows[2]
    XCTAssertFalse(m.deletesBranch(caution), "既定の `残す` では消さない")
    m.toggle(at: caution.id)
    m.chooseBranch(.delete)
    XCTAssertTrue(m.deletesBranch(caution))
  }

  func testRequestsCarryPerRowBranchDecision() {
    let m = makeModel()
    m.toggle(at: m.rows[2].id)
    m.chooseBranch(.delete)
    XCTAssertEqual(
      m.requests(),
      [
        CleanDeleteRequest(path: "/wt/safe-a", branch: "feat/a", head: "aaa", deleteBranch: true),
        CleanDeleteRequest(path: "/wt/safe-b", branch: "feat/b", head: "bbb", deleteBranch: false),
        CleanDeleteRequest(path: "/wt/caution", branch: "feat/c", head: "ccc", deleteBranch: true),
      ])
  }

  // MARK: - 3 フェーズ

  func testBeginRunEntersDeletingWithOnlySelectedRows() {
    let m = makeModel()
    m.beginRun(m.requests())
    XCTAssertEqual(m.phase, .deleting)
    XCTAssertEqual(m.run?.requests.map(\.path), ["/wt/safe-a", "/wt/safe-b"], "選んだ行だけが並ぶ")
    XCTAssertEqual(m.run?.states, [.pending, .pending])
    XCTAssertEqual(m.totalCount, 2)
  }

  func testProgressIsCountedFromStates() {
    let m = makeModel()
    m.beginRun(m.requests())
    m.markRunning(path: "/wt/safe-a")
    XCTAssertEqual(m.run?.states.first, .running)
    m.markFinished(path: "/wt/safe-a", outcome: .succeeded(branch: "feat/a", pruned: false))
    XCTAssertEqual(m.doneCount, 1)
    XCTAssertEqual(m.failedCount, 0)
    XCTAssertEqual(m.phase, .deleting, "待機が残っている間は削除中")
    m.markFinished(
      path: "/wt/safe-b", outcome: .failed(CleanFailure(step: .worktree, log: "fatal: nope")))
    XCTAssertEqual(m.doneCount, 1)
    XCTAssertEqual(m.failedCount, 1)
    XCTAssertEqual(m.phase, .failed)
  }

  /// 中断は「まだ撃っていない残り」を止める。実行中が残っている間は据わらず、撃たれないと決まった
  /// 待機はその場で `.skipped` へ落ちる（「まだ撃つものが残っている」と読める状態を残さない）。
  func testCancelSettlesOnceNothingIsRunning() {
    let m = makeModel()
    m.beginRun(m.requests())
    m.markRunning(path: "/wt/safe-a")
    m.cancelRun()
    XCTAssertTrue(m.runToken?.isCancelled == true, "札は実行側の唯一の入力")
    XCTAssertEqual(m.phase, .deleting, "撃った 1 件は完走させる")
    XCTAssertEqual(m.run?.states.last, .skipped, "未実行の待機は終端状態へ落ちる")
    m.markFinished(path: "/wt/safe-a", outcome: .succeeded(branch: nil, pruned: false))
    XCTAssertEqual(m.phase, .failed, "以降を撃たずに据わる")
    XCTAssertEqual(m.failedCount, 0, "失敗が無ければ終端は呼び手が一覧へ返す")
  }

  /// 再試行は**失敗行だけ**を撃ち直し、成功行は `.done` のまま残る。失敗行は撃たれるまで `.failed` の
  /// まま（理由と生ログを持ったまま）で、実際に撃たれた行を `markRunning` が動かす。
  func testRetryReturnsOnlyFailedRowsAndKeepsSuccesses() {
    let m = makeModel()
    m.beginRun(m.requests())
    m.markFinished(path: "/wt/safe-a", outcome: .succeeded(branch: "feat/a", pruned: false))
    m.markFinished(
      path: "/wt/safe-b", outcome: .failed(CleanFailure(step: .worktree, log: "fatal: nope")))
    let stale = m.runToken

    let retry = m.retryRequests()

    XCTAssertEqual(retry.map(\.path), ["/wt/safe-b"])
    XCTAssertEqual(
      retry.first?.deleteBranch, false, "凍結した依頼のまま（何を消すかは選択画面が決めた通り）")
    XCTAssertEqual(m.doneCount, 1, "成功行は消えない")
    XCTAssertFalse(m.runToken === stale, "中断後の再試行が即座に打ち切られないよう札を張り直す")
    m.markRunning(path: "/wt/safe-b")
    XCTAssertEqual(m.phase, .deleting)
  }

  /// 中断で未実行の行を残したまま再試行し、それがまた失敗しても据わる。
  /// **中断の事実を再試行が取り消さない**（取り消すと、二度と撃たれない待機を待って据わらなくなる）。
  func testRetryAfterCancelStillSettles() {
    let m = makeModel()
    m.toggle(at: m.rows[2].id)
    m.beginRun(m.requests())
    m.markRunning(path: "/wt/safe-a")
    m.cancelRun()
    let failure = CleanFailure(step: .dirty, log: "")
    m.markFinished(path: "/wt/safe-a", outcome: .failed(failure))
    XCTAssertEqual(m.phase, .failed, "未実行の行が残っていても据わる")

    let retry = m.retryRequests()
    XCTAssertEqual(retry.map(\.path), ["/wt/safe-a"], "撃ち直すのは失敗行だけ")
    m.markRunning(path: "/wt/safe-a")
    m.markFinished(path: "/wt/safe-a", outcome: .failed(failure))

    XCTAssertEqual(m.phase, .failed, "再び失敗しても削除中に据わらない")
    XCTAssertEqual(m.failureTargetPath, "/wt/safe-a", "対処の導線が生きている")
  }

  /// 再試行の途中で中断すると、**まだ撃っていない失敗行は失敗のまま残る**
  /// （待機へ倒すと、理由も生ログも消えたまま「全件成功」の終端へ落ちる）。
  func testCancelDuringRetryKeepsUnfiredFailures() {
    let m = makeModel()
    m.beginRun(m.requests())
    let failure = CleanFailure(step: .worktree, log: "fatal: nope")
    m.markFinished(path: "/wt/safe-a", outcome: .failed(failure))
    m.markFinished(path: "/wt/safe-b", outcome: .failed(failure))

    _ = m.retryRequests()
    m.markRunning(path: "/wt/safe-a")
    m.cancelRun()
    m.markFinished(path: "/wt/safe-a", outcome: .succeeded(branch: nil, pruned: false))

    XCTAssertEqual(m.failedCount, 1, "撃たれなかった失敗行は消えない")
    XCTAssertEqual(m.run?.states.last, .failed(failure), "理由と生ログもそのまま")
    XCTAssertEqual(m.phase, .failed)
  }

  /// ブランチ削除だけが落ちた行の再試行は、**worktree が既に消えている**ことを依頼へ書き戻す。
  /// 実体の無いパスへ status を撃つと必ず失敗し、「未コミットの変更がある」という逆の理由が出る。
  func testRetryOfBranchFailureSkipsTheWorktreeStep() {
    let m = makeModel()
    m.beginRun(m.requests())
    m.markFinished(
      path: "/wt/safe-a",
      outcome: .failed(CleanFailure(step: .branch, log: "fatal: cannot lock ref")))
    m.markFinished(path: "/wt/safe-b", outcome: .succeeded(branch: nil, pruned: false))

    let retry = m.retryRequests()

    XCTAssertEqual(retry.map(\.path), ["/wt/safe-a"])
    XCTAssertEqual(retry.map(\.worktreeAlreadyRemoved), [true])
    XCTAssertEqual(retry.first?.deleteBranch, true, "残っているのはブランチ削除だけ")
    XCTAssertNil(m.openableFailurePath, "開く先の worktree がもう無い")
  }

  /// 一部失敗画面のカーソルは**失敗行だけ**を巡回する（`o` の対象がそこから決まる）。
  func testFailureCursorWalksFailedRowsOnly() {
    let m = makeModel()
    m.toggle(at: m.rows[2].id)
    m.beginRun(m.requests())
    m.markFinished(path: "/wt/safe-a", outcome: .succeeded(branch: nil, pruned: false))
    let failure = CleanFailure(step: .worktree, log: "fatal: nope")
    m.markFinished(path: "/wt/safe-b", outcome: .failed(failure))
    m.markFinished(path: "/wt/caution", outcome: .failed(failure))

    XCTAssertEqual(m.phase, .failed)
    XCTAssertEqual(m.failureTargetPath, "/wt/safe-b")
    m.move(1)
    XCTAssertEqual(m.failureTargetPath, "/wt/caution")
    m.move(1)
    XCTAssertEqual(m.failureTargetPath, "/wt/safe-b", "端で wrap する")
  }

  func testEndRunReturnsToSelecting() {
    let m = makeModel()
    m.beginRun(m.requests())
    m.endRun()
    XCTAssertEqual(m.phase, .selecting)
    XCTAssertNil(m.run)
  }
}
