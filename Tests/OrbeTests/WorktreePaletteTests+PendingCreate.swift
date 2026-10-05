import XCTest

@testable import Orbe

/// 提示時の fetch の着地を待つ作成行の預かり: 預けた ↵ とタップは、着地の後に組み直した一覧の選択ではなく、
/// 打った名前の意図で決まる。作れない名前は待たず、待つ間はそれを示す。
///
/// 壊れると何が起きるか: 新しい名前を打って着地前に ↵ を押すと、着地で届いた名前の一部が一致するだけの
/// 別のリモートブランチの worktree が作られて起動する（タスクから開いていればそのタスクも進行中になる）。
/// 作れない名前の ↵ が着地まで預かられ、その間 esc も入力も効かずに固まって見える。待つ間の画面が何も
/// 言わず、作成行のタップが黙って捨てられる。
@MainActor
extension WorktreePaletteTests {
  /// 着地前の作成行を ↵ で預けた画面（手元のどれとも一致しない名前 `name`）。
  private func pendingCreate(_ name: String) -> (
    WorktreePaletteModel, () -> [WorktreePaletteDestination]
  ) {
    let p = makeCreatableModel(remoteBranchesLanded: false)
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    type(name, into: p)
    p.activate()
    XCTAssertTrue(p.hasPendingActivation, "前提: ↵ は預かられる")
    return (p, { executed })
  }

  /// 着地した一覧（designSample にリモートブランチ・ローカルブランチを足したもの）を届ける。
  private func land(
    _ p: WorktreePaletteModel, remotes: [String], locals: [String] = []
  ) {
    var input = WorktreePaletteSectionBuilder.Input.designSample
    input.remoteBranches.insert(
      contentsOf: remotes.map { GitBranch(name: $0, relativeDate: "now", upstream: nil) }, at: 0)
    input.localBranches.insert(
      contentsOf: locals.map { GitBranch(name: $0, relativeDate: "now", upstream: nil) }, at: 0)
    p.newBranchRules = newBranchRules(input)
    rebuild(p, with: input)
  }

  // MARK: - 預けた意図で決まる

  /// 着地で名前の一部が一致するだけのリモートブランチが届いても、作成行が残っていれば作る。
  func testHeldEnterCreatesWhenTheCreateRowSurvivesAPartialRemoteMatch() {
    let (p, executed) = pendingCreate("topic")

    land(p, remotes: ["origin/feature/topic-x"])

    XCTAssertEqual(executed(), [.newBranch(name: "topic", base: .ref("origin/release/0.8"))])
    XCTAssertFalse(p.hasPendingActivation)
  }

  /// 作成行が消え、名前の一部が一致するだけのリモートブランチしか無ければ、何も実行しない。
  func testHeldEnterDoesNothingWhenOnlyAPartialRemoteMatchRemains() {
    let (p, executed) = pendingCreate("topic")

    land(p, remotes: ["origin/feature/topic-x"], locals: ["topic/old"])

    XCTAssertEqual(executed(), [])
    XCTAssertFalse(p.hasPendingActivation, "預かりは解く")
  }

  /// 同じ名前のリモートブランチと、それより新しい部分一致のリモートブランチが同時に届いたら、同じ名前の方を
  /// 開く。
  func testHeldEnterOpensTheSameNamedRemoteOverANewerPartialMatch() {
    let (p, executed) = pendingCreate("topic")

    land(p, remotes: ["origin/feature/topic-x", "origin/topic"])

    XCTAssertEqual(executed(), [.remoteBranch(name: "origin/topic", existingWorktree: nil)])
  }

  /// 矢印で作成行を選んで預けた ↵ も同じ（同じ名前のリモートブランチを開く）。
  func testHeldEnterOnACreateRowChosenWithArrowsOpensTheSameNamedRemote() {
    let p = makeCreatableModel(remoteBranchesLanded: false)
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    type("login", into: p)
    XCTAssertEqual(p.selectedItem?.name, "fix/login-blank", "前提: 一致する既存の行が選ばれる")
    p.move(-1)
    XCTAssertEqual(p.selectedItem?.action, .createBranch(name: "login"), "前提: 作成行へ動かした")
    p.activate()
    XCTAssertTrue(p.hasPendingActivation)

    land(p, remotes: ["origin/feature/login-x", "origin/login"])

    XCTAssertEqual(executed, [.remoteBranch(name: "origin/login", existingWorktree: nil)])
  }

  // MARK: - 作れない名前は待たない

  /// 作成行が出ない名前（無効・`-` 始まり・ローカルブランチと親子・作成先が既存の worktree）は、着地を待たない
  /// ——↵ を預からず、esc も効く。
  func testEnterOnANameThatCannotBeCreatedIsNotHeldBeforeTheFetchLands() {
    for (name, valid) in [
      ("bad..name", false), ("-zz", true), ("fix/login-blank/sub", true), ("pr/214", true),
    ] {
      let p = makeCreatableModel(remoteBranchesLanded: false)
      p.query = name
      p.onQueryChanged()
      if !name.hasPrefix("-") { p.applyBranchNameCheck(name, isValid: valid) }
      XCTAssertTrue(p.items.isEmpty, "前提: \(name) に一致する行も作成行も無い")

      p.activate()

      XCTAssertFalse(p.hasPendingActivation, name)
      XCTAssertFalse(p.isLocked, "\(name): esc と入力が効く")
    }
  }

  // MARK: - 待つ間を示す・タップも預かる

  /// 着地前の作成行は、↵ でもタップでも預かり、その間はリモートのブランチを確かめていると示す。着地すると
  /// 決着し、示すのをやめる。
  func testHeldCreateShowsItIsCheckingRemoteBranchesUntilTheFetchLands() throws {
    let (entered, _) = pendingCreate("topic")
    XCTAssertTrue(entered.isAwaitingRemoteBranches, "↵")

    let p = makeCreatableModel(remoteBranchesLanded: false)
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    type("topic", into: p)
    XCTAssertFalse(p.isAwaitingRemoteBranches, "預ける前は示さない")
    let row = try XCTUnwrap(p.items.firstIndex { $0.action == .createBranch(name: "topic") })
    p.activate(at: row)
    XCTAssertTrue(p.hasPendingActivation, "タップも預かる")
    XCTAssertTrue(p.isAwaitingRemoteBranches, "タップ")

    land(p, remotes: [])

    XCTAssertFalse(p.isAwaitingRemoteBranches)
    XCTAssertEqual(executed, [.newBranch(name: "topic", base: .ref("origin/release/0.8"))])
  }

  /// 預かりの理由が有効性の答えだけ（着地済み）なら、リモートのブランチを確かめているとは示さない。
  func testWaitingOnlyForTheNameAnswerIsNotShownAsCheckingRemoteBranches() {
    let p = makeCreatableModel()
    type("topic", into: p, valid: nil)
    p.activate()

    XCTAssertTrue(p.hasPendingActivation, "前提: 答えを待って預かる")
    XCTAssertFalse(p.isAwaitingRemoteBranches)
  }

  // MARK: - タスクから開いた ⌘T

  /// #221（未着手）の文脈で開き、先頭の欄が `target` のモデル。`landed` は提示時の fetch が着地したか。
  private func taskContextModel(
    _ target: WorktreePaletteTaskTarget, landed: Bool, remotes: [String] = []
  ) -> (WorktreePaletteModel, WorktreePaletteSectionBuilder.Input) {
    var input = WorktreePaletteSectionBuilder.Input.designSample
    input.taskTarget = target
    input.taskNumber = 221
    input.remoteBranches.insert(
      contentsOf: remotes.map { GitBranch(name: $0, relativeDate: "now", upstream: nil) }, at: 0)
    input.newBranchRules = newBranchRules(input, remoteBranchesLanded: landed)
    let p = DesignSceneFixtures.worktreePaletteModel(from: input, task: 3)
    DesignSceneFixtures.setDesignBase(p)
    p.newBranchRules = input.newBranchRules
    p.taskTargetPending = target == .pending
    return (p, input)
  }

  /// 打った名前の有効性の答えを待つ間に、先頭の欄の作成行を選んで ↵ を押すと、答えが届いたときに作るのは
  /// その行のブランチで、打った名前のブランチではない。同じ行をタップしても同じ結果になる。
  func testHeldEnterOnTheTaskCreateRowCreatesThatRowsBranchLikeATap() throws {
    var results: [[WorktreePaletteDestination]] = []
    for tap in [false, true] {
      let (p, _) = taskContextModel(
        .branch(name: "issue/221", pullRequest: nil, remotes: ["origin"]), landed: true)
      var executed: [WorktreePaletteDestination] = []
      p.onExecute = { executed.append($0) }
      type("issue/22", into: p, valid: nil)
      let row = try XCTUnwrap(
        p.items.firstIndex { $0.action == .createBranch(name: "issue/221") }, "前提: 欄の作成行")
      p.move(row - p.selected)

      if tap { p.activate(at: row) } else { p.activate() }
      XCTAssertTrue(p.hasPendingActivation, "前提: 答えを待って預かる")
      p.applyBranchNameCheck("issue/22", isValid: true)

      XCTAssertEqual(executed.count, 1, tap ? "タップ" : "↵")
      guard case .newBranch(let name, _) = executed.first else {
        return XCTFail("作成されない: \(executed)")
      }
      XCTAssertEqual(name, "issue/221", tap ? "タップ" : "↵")
      results.append(executed)
    }
    XCTAssertEqual(results[0], results[1], "↵ とタップで同じ")
  }

  /// 先頭の欄が決まる前（手元に無いブランチを待つ間）に、手元に無い名前を打って ↵ を押すと、その時点で打った
  /// 名前を作る意図として預かる。着地で名前の一部が一致するだけのリモートブランチが届いても、作るのは打った
  /// 名前のブランチ。
  func testEnterBeforeTheTaskTargetLandsKeepsTheTypedNameToCreate() {
    let (p, _) = taskContextModel(.pending, landed: false)
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    type("221", into: p)

    p.activate()
    XCTAssertEqual(p.pendingActivation, .create(name: "221"))

    let (_, landed) = taskContextModel(
      .branch(name: "issue/221", pullRequest: nil, remotes: ["origin"]), landed: true,
      remotes: ["origin/feature/221-x"])
    p.taskTargetPending = false
    p.newBranchRules = newBranchRules(landed)
    rebuild(p, with: landed)

    XCTAssertEqual(executed.count, 1)
    guard case .newBranch(let name, _) = executed.first else {
      return XCTFail("作成されない: \(executed)")
    }
    XCTAssertEqual(name, "221")
  }
}
