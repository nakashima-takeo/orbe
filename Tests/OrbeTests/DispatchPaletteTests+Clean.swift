import XCTest

@testable import Orbe

/// list / clean の 2 モードを持つカードの遷移契約と、clean の 3 画面で意味の変わるキーの畳み方。
/// `DispatchCleanModel` の中身は `DispatchCleanModelTests` が持つ。
@MainActor
extension DispatchPaletteTests {

  /// **`clean` 行はパレット内の画面遷移で、外の決定経路には出さない。**
  /// ここが崩れると `DispatchDataProvider.prepareDirectory` に `.clean` が届き、completion が
  /// 呼ばれず `isPreparing` が立ったままパレットが閉じられなくなる（release では assertion も消える）。
  func testCleanRowEntersCleanModeInsteadOfExecuting() throws {
    let p = makeModel()
    p.classification = cleanRows()
    var executed: [DispatchItem] = []
    p.onExecute = { executed.append($0) }

    p.activate(at: try XCTUnwrap(p.items.firstIndex { $0.action == .clean }))
    XCTAssertTrue(executed.isEmpty, "clean 行は onExecute に流さない")
    XCTAssertEqual(p.mode, .clean)
    XCTAssertEqual(p.clean.rows.map(\.name), ["a"], "分類スナップショットで開く")
  }

  /// 分類が未着地なら握り潰す（list に留まる）。
  func testCleanRowIsInertUntilClassificationLands() throws {
    let p = makeModel()
    var executed: [DispatchItem] = []
    p.onExecute = { executed.append($0) }

    p.activate(at: try XCTUnwrap(p.items.firstIndex { $0.action == .clean }))
    XCTAssertTrue(executed.isEmpty)
    XCTAssertEqual(p.mode, .list, "未着地では画面が変わらない")
  }

  /// esc で list へ戻ると、カーソルは入口の `clean` 行を指す。
  func testExitCleanReturnsCursorToCleanRow() {
    let p = makeModel()
    p.classification = []
    p.selected = 0
    p.enterClean()
    p.exitOrCancelClean()
    XCTAssertEqual(p.mode, .list)
    XCTAssertEqual(p.selectedItem?.action, .clean)
  }

  /// ⌘⏎ は削除中の札ごと実行側へ渡す唯一の funnel。
  func testExecuteCleanBeginsRunAndHandsOverTheToken() {
    let p = makeModel()
    p.classification = cleanRows()
    p.enterClean()
    var handed: [(requests: [CleanDeleteRequest], token: CleanRunToken)] = []
    p.onCleanExecute = { handed.append(($0, $1)) }

    p.executeClean()

    XCTAssertEqual(handed.count, 1)
    XCTAssertEqual(handed.first?.requests.map(\.path), ["/wt/a"])
    XCTAssertTrue(handed.first?.token === p.clean.runToken)
    XCTAssertEqual(p.clean.phase, .deleting)
  }

  /// ⏎ は画面ごとに畳む: 選択画面ではチェック、削除中は無反応、一部失敗画面では失敗分の再試行。
  func testConfirmFoldsPerPhase() {
    let p = makeModel()
    p.classification = cleanRows()
    p.enterClean()
    var handed: [[CleanDeleteRequest]] = []
    p.onCleanExecute = { requests, _ in handed.append(requests) }

    p.confirmClean()
    XCTAssertFalse(p.clean.isChecked(p.clean.rows[0]), "選択画面ではチェックを切り替える")

    p.clean.beginRun([
      CleanDeleteRequest(path: "/wt/a", branch: "a", head: "x", deleteBranch: false)
    ])
    p.confirmClean()
    XCTAssertTrue(handed.isEmpty, "削除中の ⏎ は無反応")

    p.clean.markFinished(
      path: "/wt/a", outcome: .failed(CleanFailure(step: .worktree, log: "fatal: nope")))
    p.confirmClean()
    XCTAssertEqual(handed.map { $0.map(\.path) }, [["/wt/a"]], "一部失敗画面では失敗分を撃ち直す")
  }

  /// esc も画面ごとに畳む: 選択画面は一覧へ、削除中は中断、一部失敗画面はパレットを閉じる。
  func testEscapeFoldsPerPhase() {
    let p = makeModel()
    p.classification = cleanRows()
    p.enterClean()
    var dismissed = 0
    p.onDismiss = { dismissed += 1 }

    let requests = [CleanDeleteRequest(path: "/wt/a", branch: "a", head: "x", deleteBranch: false)]
    p.clean.beginRun(requests)
    p.exitOrCancelClean()
    XCTAssertTrue(p.clean.runToken?.isCancelled == true, "削除中の esc は中断")
    XCTAssertEqual(dismissed, 0)

    p.clean.markFinished(
      path: "/wt/a", outcome: .failed(CleanFailure(step: .worktree, log: "fatal: nope")))
    p.exitOrCancelClean()
    XCTAssertEqual(dismissed, 1, "一部失敗画面の esc は閉じる")
  }

  /// `o` は一部失敗画面のカーソルが指す失敗行のパスで撃つ（`prepareDirectory` を通らない）。
  func testOpenCleanFailureUsesTheCursorRowPath() {
    let p = makeModel()
    p.classification = cleanRows()
    p.enterClean()
    var opened: [String] = []
    p.onOpenWorktree = { opened.append($0) }

    p.openCleanFailure()
    XCTAssertTrue(opened.isEmpty, "選択画面では効かない")

    p.clean.beginRun([
      CleanDeleteRequest(path: "/wt/a", branch: "a", head: "x", deleteBranch: false)
    ])
    p.clean.markFinished(
      path: "/wt/a", outcome: .failed(CleanFailure(step: .worktree, log: "fatal: nope")))
    p.openCleanFailure()
    XCTAssertEqual(opened, ["/wt/a"])
  }

  /// **失敗が 1 件も無ければ clean を抜けて一覧へ戻る**（中断も同じ終端を通る）。
  func testSettleReturnsToListWhenNothingFailed() {
    let p = makeModel()
    p.classification = cleanRows()
    p.enterClean()
    p.clean.beginRun([
      CleanDeleteRequest(path: "/wt/a", branch: "a", head: "x", deleteBranch: false)
    ])
    p.clean.markFinished(path: "/wt/a", outcome: .succeeded(branch: "a", pruned: false))

    p.settleCleanRun()

    XCTAssertEqual(p.mode, .list)
    XCTAssertEqual(p.clean.phase, .selecting)
    XCTAssertEqual(p.selectedItem?.action, .clean, "カーソルは入口の clean 行")
  }

  /// 失敗があれば一部失敗画面に留まる（成功行を消さない）。
  func testSettleStaysOnFailureScreen() {
    let p = makeModel()
    p.classification = cleanRows()
    p.enterClean()
    p.clean.beginRun([
      CleanDeleteRequest(path: "/wt/a", branch: "a", head: "x", deleteBranch: false)
    ])
    p.clean.markFinished(
      path: "/wt/a", outcome: .failed(CleanFailure(step: .worktree, log: "fatal: nope")))

    p.settleCleanRun()

    XCTAssertEqual(p.mode, .clean)
    XCTAssertEqual(p.clean.phase, .failed)
  }

  private func cleanRows() -> [CleanRow] {
    DispatchWorktreeClassifier.classify(
      [
        DispatchCleanFacts(
          path: "/wt/a", branch: "feat/a", head: "aaa", upstream: "origin/feat/a",
          track: "[gone]", status: GitWorktreeStatusCounts(modified: 0, untracked: 0),
          unmergedCommits: 0, operation: .none)
      ], defaultBranch: "main")
  }
}
