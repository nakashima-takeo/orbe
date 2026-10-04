import XCTest

@testable import Orbe

/// タスクから開いた ⌘T の先頭の欄の行の選び方、↵ がタスクに起こすこと（フッターが先に言う内容）、worktree の
/// 行に出るタスク。題材は見本のタスク（#212 が ~/wt/issue-212 を持って進行中、#221 は未着手）。
///
/// 壊れると何が起きるか: 既にある worktree・ブランチを差し置いて同じ名前のブランチを作ろうとする。フッターが
/// 付け替えを言わないまま、別のタスクの worktree を黙って奪う。何も変わらないのに「進行中に」と言う。
/// いつもの ⌘T で、どの worktree がどのタスクの作業場所か分からない。
@MainActor
extension WorktreePaletteTests {
  /// 見本の一覧に `target` の欄を足し、#221（未着手）の文脈で開いたモデル。
  private func taskModel(
    _ target: WorktreePaletteTaskTarget, task: Int = 3,
    _ mutate: (inout WorktreePaletteSectionBuilder.Input) -> Void = { _ in }
  ) -> WorktreePaletteModel {
    var input = WorktreePaletteSectionBuilder.Input.designSample
    input.taskTarget = target
    input.taskNumber = 221
    input.newBranchRules = DesignSceneFixtures.designNewBranchRules
    mutate(&input)
    let model = DesignSceneFixtures.worktreePaletteModel(from: input, task: task)
    DesignSceneFixtures.setDesignBase(model)
    return model
  }

  private var issue212Path: String { NSHomeDirectory() + "/wt/issue-212" }

  private func select(_ action: WorktreePaletteAction, in model: WorktreePaletteModel) throws {
    let index = try XCTUnwrap(model.items.firstIndex { $0.action == action })
    model.move(index - model.selected)
  }

  // MARK: - 先頭の欄の行

  /// ブランチが既に worktree にあれば、作らずにその worktree を開く。
  func testTheBranchsExistingWorktreeIsOfferedInsteadOfCreatingIt() {
    let model = taskModel(.branch(name: "issue/212", pullRequest: nil, remotes: ["origin"]))

    XCTAssertEqual(model.visibleSections.first?.title, .task(number: 221))
    XCTAssertEqual(
      model.visibleSections.first?.items.map(\.action), [.open(.directory(path: issue212Path))])
  }

  /// PR のブランチがローカルに無ければ、そのリポジトリの remote のブランチを開く。
  func testAPullRequestBranchOnlyOnTheRemoteIsOfferedFromTheRemote() {
    let model = taskModel(
      .branch(name: "feat/fetch-progress", pullRequest: 230, remotes: ["origin"]))

    let row = model.visibleSections.first?.items.first
    XCTAssertEqual(
      row?.action,
      .open(.remoteBranch(name: "origin/feat/fetch-progress", existingWorktree: nil)))
    XCTAssertEqual(row?.pullRequest, 230)
    XCTAssertEqual(
      model.items.filter { $0.action == row?.action }.count, 1, "下の BRANCHES に同じ行を出さない")
  }

  /// 入力した名前が先頭の欄の作成行と同じなら、作成行は 1 つだけ。
  func testTypingTheTasksBranchNameKeepsASingleCreateRow() {
    let model = taskModel(.branch(name: "issue/221", pullRequest: nil, remotes: ["origin"]))
    XCTAssertEqual(model.selectedItem?.action, .createBranch(name: "issue/221"), "前提: 欄の作成行")

    type("issue/221", into: model)

    XCTAssertEqual(
      model.items.filter { $0.action == .createBranch(name: "issue/221") }.count, 1)
  }

  // MARK: - ↵ がタスクに起こすこと

  func testEnterOnTheTaskRowStartsATodoTask() {
    let model = taskModel(.branch(name: "issue/221", pullRequest: nil, remotes: ["origin"]))

    XCTAssertEqual(model.taskEffect?.task.id, 3)
    XCTAssertEqual(model.taskEffect?.begins, true)
    XCTAssertNil(model.taskEffect?.previousOwner)
  }

  func testChoosingAWorktreeHeldByAnotherTaskSaysItMovesFromThatTask() throws {
    let model = taskModel(.branch(name: "issue/221", pullRequest: nil, remotes: ["origin"]))

    try select(.open(.directory(path: issue212Path)), in: model)

    XCTAssertEqual(model.taskEffect?.previousOwner?.id, 1, "#212 から付け替える")
    XCTAssertEqual(model.taskEffect?.begins, true)
  }

  /// リモートブランチの行でも、↵ が既存の worktree を開くなら、その worktree の持ち主からの付け替えを言う。
  func testARemoteBranchRowOpeningAnotherTasksWorktreeSaysItMovesFromThatTask() throws {
    let model = taskModel(.branch(name: "issue/221", pullRequest: nil, remotes: ["origin"])) {
      $0.localBranches.removeAll { $0.name == "pr-214" }
      $0.remoteBranches.append(GitBranch(name: "origin/pr-214", relativeDate: "2d", upstream: nil))
    }
    let row = WorktreePaletteAction.open(
      .remoteBranch(name: "origin/pr-214", existingWorktree: NSHomeDirectory() + "/wt/pr-214"))

    try select(row, in: model)

    XCTAssertEqual(model.taskEffect?.previousOwner?.id, 2, "#214 から付け替える")
  }

  /// 進行中のタスクが自分の worktree を開くだけなら、タスクは何も変わらない。
  func testNothingIsSaidWhenAnInProgressTaskOpensItsOwnWorktree() {
    let model = taskModel(.worktree(path: issue212Path), task: 1)
    XCTAssertEqual(model.selectedItem?.action, .open(.directory(path: issue212Path)))

    XCTAssertNil(model.taskEffect)
  }

  /// clean の行の ↵ は worktree を用意しないので、未着手のタスクでも何も言わない。
  func testNothingIsSaidOnTheCleanRow() throws {
    let model = taskModel(.branch(name: "issue/221", pullRequest: nil, remotes: ["origin"]))

    try select(.clean, in: model)

    XCTAssertNil(model.taskEffect)
  }

  /// 文脈を外すと、↵ はタスクに何も起こさない。
  func testClearingTheContextLeavesTheTaskAlone() {
    let model = taskModel(.branch(name: "issue/221", pullRequest: nil, remotes: ["origin"]))

    model.clearTaskContext()

    XCTAssertNil(model.task)
    XCTAssertNil(model.taskEffect)
    XCTAssertEqual(model.taskInputs, .none, "先頭の欄の入力も消える（provider が欄を外す）")
  }

  /// 札とフッターはタスクを主の番号で呼び、結び付きが無ければタイトルで呼ぶ。
  func testTheTaskIsCalledByItsPrimaryNumberOrElseByItsTitle() {
    let l10n = LocalizationStore(language: .ja)
    let linked = TaskPaletteSamples.task(1, "設計") {
      $0.links = [TaskPaletteSamples.link(.issue, 221), TaskPaletteSamples.link(.pr, 230)]
    }
    let bare = TaskPaletteSamples.task(2, "請求書を送る")

    XCTAssertEqual(WorktreePaletteTaskText.name(linked, l10n), "#221")
    XCTAssertEqual(WorktreePaletteTaskText.name(bare, l10n), "『請求書を送る』")
  }

  // MARK: - worktree の行のタスク

  /// いつもの ⌘T（文脈なし）でも、worktree の行にその worktree を持つタスクと agent が出る。
  func testAWorktreeRowShowsTheTaskHoldingItWithoutAContext() throws {
    let model = DesignSceneFixtures.worktreePaletteModel()
    XCTAssertNil(model.task, "前提: いつもの ⌘T")

    let row = try XCTUnwrap(
      model.items.first { $0.action == .open(.directory(path: issue212Path)) })
    let free = try XCTUnwrap(
      model.items.first { $0.name == "perf-render-batching" })

    XCTAssertEqual(model.rowTask(row)?.task.id, 1)
    XCTAssertEqual(model.rowTask(row)?.agent?.state, .working)
    XCTAssertNil(model.rowTask(free), "どのタスクも持たない worktree")
  }
}
