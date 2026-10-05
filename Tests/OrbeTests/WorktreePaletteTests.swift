import XCTest

@testable import Orbe

/// worktree パレット（WorktreePaletteModel）のロジック検証。libghostty 非依存（@Observable モデルのみ）。
/// live git/gh は叩かず `WorktreePaletteSectionBuilder` に mock 入力を通してセクションを組む。
@MainActor
final class WorktreePaletteTests: OrbeTestCase {

  /// provider の初回 rebuild と同じ順（ロード完了 → 行 → 選択の当て直し）で組む。
  func makeModel(
    _ input: WorktreePaletteSectionBuilder.Input = .designSample,
    agents: [AgentCLI] = [
      AgentCLI(command: "claude", path: "/bin/claude"),
      AgentCLI(command: "codex", path: "/bin/codex"),
    ]
  ) -> WorktreePaletteModel {
    let model = WorktreePaletteModel()
    model.setTargets(agents: agents, defaultCommand: "claude")
    model.hasLoadedOnce = true
    model.sections = WorktreePaletteSectionBuilder.build(input)
    model.restoreSelection(matching: nil)
    return model
  }

  /// 開いた直後は今の worktree の行が選ばれる（⌘T ↵ ＝今の worktree で既定の agent）。先頭でなくても選ばれる。
  func testInitialSelectionFindsTheCurrentWorktreeAnywhere() {
    var input = WorktreePaletteSectionBuilder.Input.designSample
    input.currentWorktree = NSHomeDirectory() + "/wt/perf-render-batching"
    let p = makeModel(input)
    XCTAssertEqual(p.selectedItem?.name, "perf-render-batching")
    XCTAssertTrue(p.selectedItem?.isCurrent ?? false)
  }

  func testMoveWrapsAcrossSections() {
    let p = makeModel()
    p.move(-1)
    XCTAssertEqual(p.selected, 5, "先頭で上 → 末尾へ wrap")
    XCTAssertEqual(p.selectedItem?.name, "origin/feat/fetch-progress", "末尾は remote branch 行")
    p.move(1)
    XCTAssertEqual(p.selected, 0, "末尾から下 → 先頭へ wrap")
  }

  // MARK: - 起動先

  /// 並びは既定の agent、shell、残りの agent（検出順）。初期は既定の agent。
  func testTargetsPutDefaultFirstThenShellThenOthers() {
    let codex = AgentCLI(command: "codex", path: "/bin/codex")
    let claude = AgentCLI(command: "claude", path: "/bin/claude")
    let agy = AgentCLI(command: "agy", path: "/bin/agy")
    let p = WorktreePaletteModel()
    p.setTargets(agents: [codex, claude, agy], defaultCommand: "claude")
    XCTAssertEqual(p.targets, [.agent(claude), .shell, .agent(codex), .agent(agy)])
    XCTAssertEqual(p.selectedTargetName, "claude", "初期は既定の agent")
    XCTAssertEqual(p.defaultTarget, .agent(claude), "「既定」の札は既定の agent")
  }

  func testTargetsFallBackToFirstAgentWhenDefaultIsAbsent() {
    let p = WorktreePaletteModel()
    p.setTargets(
      agents: [
        AgentCLI(command: "codex", path: "/bin/codex"),
        AgentCLI(command: "claude", path: "/bin/claude"),
      ], defaultCommand: "missing")
    XCTAssertEqual(p.selectedTargetName, "codex", "既定が検出に無ければ検出順の先頭")
  }

  func testCycleTarget() {
    let p = makeModel()
    XCTAssertEqual(p.selectedTargetName, "claude")
    p.cycleTarget()
    XCTAssertEqual(p.selectedTargetName, "shell", "⇥ 一回で既定の直後の shell へ")
    p.cycleTarget()
    XCTAssertEqual(p.selectedTargetName, "codex")
    p.cycleTarget()
    XCTAssertEqual(p.selectedTargetName, "claude", "巡回は端で wrap")
  }

  /// agent 未検出でも shell が選ばれ、「既定」の札は付かない。
  func testShellSelectableWithoutAgents() {
    let p = makeModel(agents: [])
    XCTAssertEqual(p.targets, [.shell])
    XCTAssertEqual(p.selectedTarget, .shell)
    XCTAssertNil(p.defaultTarget)
  }

  /// ボタンのクリックでその起動先を選ぶ。入力ロック中は動かない。
  func testChooseTargetByClick() {
    let p = makeModel()
    p.chooseTarget(at: 2)
    XCTAssertEqual(p.selectedTargetName, "codex")
    p.isPreparing = true
    p.chooseTarget(at: 1)
    XCTAssertEqual(p.selectedTargetName, "codex", "作成中は変えない")
  }

  // MARK: - 決定

  /// ↵ は今の worktree のルートを開く。
  func testEnterOpensTheCurrentWorktreeRoot() {
    let p = makeModel()
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    p.activate()
    XCTAssertEqual(executed, [.directory(path: NSHomeDirectory() + "/wt/issue-212")])
  }

  /// 行タップは ↵ と同じ決定 funnel を通り、選択をその行へ移したうえで同じ行を実行する。
  func testActivateAtRowSelectsAndExecutesSameRow() {
    let p = makeModel()
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    p.activate(at: 4)  // fix/login-blank の行をタップ
    XCTAssertEqual(p.selected, 4, "タップで選択もその行へ移る")
    XCTAssertEqual(executed, [.localBranch(name: "fix/login-blank")])

    // ↵（選択行の決定）と同一の結果になる＝クリック用の別経路を持たない。
    var byEnter: [WorktreePaletteDestination] = []
    p.onExecute = { byEnter.append($0) }
    p.activate()
    XCTAssertEqual(byEnter, executed)
  }

  /// 作成中（worktree 作成待ち）はタップの重複実行を弾く。Enter 連打ガードと同じ関門を通る。
  func testActivateBlockedWhilePreparing() {
    let p = makeModel()
    var executed = 0
    p.onExecute = { _ in executed += 1 }
    p.isPreparing = true
    p.activate(at: 3)
    p.activate()
    XCTAssertEqual(executed, 0, "作成中は決定が走らない")
    XCTAssertEqual(p.selected, 0, "選択も動かさない")
  }

  /// 範囲外 index（行集合の入れ替えと競合したタップ）は no-op。
  func testActivateOutOfRangeIsSafe() {
    let p = makeModel()
    var executed = 0
    p.onExecute = { _ in executed += 1 }
    p.activate(at: 99)
    XCTAssertEqual(executed, 0)
    XCTAssertEqual(p.selected, 0)
  }

  // MARK: - 行が決まる前の ↵

  /// 初回の一覧が届く前の ↵ は預かり、届いた時点の選択（今の worktree）で実行する。預かっている間は
  /// 入力ロック。
  func testEnterBeforeTheFirstListIsHeldThenRunsOnTheCurrentWorktree() {
    let p = WorktreePaletteModel()
    p.setTargets(agents: [], defaultCommand: nil)
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }

    p.activate()
    XCTAssertTrue(executed.isEmpty, "行が決まるまで実行しない")
    XCTAssertTrue(p.isLocked, "預かっている間は入力ロック")

    p.hasLoadedOnce = true
    p.sections = WorktreePaletteSectionBuilder.build(.designSample)
    p.restoreSelection(matching: nil)

    XCTAssertEqual(executed, [.directory(path: NSHomeDirectory() + "/wt/issue-212")])
    XCTAssertFalse(p.hasPendingActivation)
  }

  /// 非 git の場所では「このディレクトリ」の行が届き、預かった ↵ はそこを開く。
  func testEnterBeforeTheFirstListInANonGitPlaceOpensThisDirectory() {
    let p = WorktreePaletteModel()
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    p.activate()

    p.hasLoadedOnce = true
    p.sections = WorktreePaletteSectionBuilder.directorySections(path: "/tmp/plain")
    p.restoreSelection(matching: nil)

    XCTAssertEqual(executed, [.directory(path: "/tmp/plain")])
  }

  // MARK: - ホバー追従（汎用パレットと共有する ModalSelection のガード）

  /// 実マウス移動後（`.pointer`）はホバーで選択がその行へ移る。決定（onExecute）は走らない。
  func testHoverFollowsSelectionWithoutExecuting() {
    let p = makeModel()
    var executed = 0
    p.onExecute = { _ in executed += 1 }
    p.inputModality = .pointer
    p.hoverSelect(3)
    XCTAssertEqual(p.selected, 3, "ホバーで選択が追従する")
    XCTAssertEqual(executed, 0, "ホバーでは決定が走らない")
  }

  /// 範囲外・作成中では追従しない。
  func testHoverIgnoresBlockedStates() {
    let p = makeModel()
    p.inputModality = .pointer
    p.hoverSelect(99)
    XCTAssertEqual(p.selected, 0, "範囲外は no-op")
    p.isPreparing = true
    p.hoverSelect(2)
    XCTAssertEqual(p.selected, 0, "作成中はキー操作と同様に受け付けない")
  }

  // MARK: - 選択復元（裏の git 列挙の引き直しによる sections 差し替え）

  /// provider の rebuild と同じ手順（選択 action を控える → sections 差し替え → 復元）。
  func rebuild(_ p: WorktreePaletteModel, with input: WorktreePaletteSectionBuilder.Input) {
    let action = p.selectedItem?.action
    p.sections = WorktreePaletteSectionBuilder.build(input)
    p.restoreSelection(matching: action)
  }

  /// ユーザーが動かした選択は、ブランチが増えて index がずれても同じ行に追従する。
  func testRestoreSelectionFollowsRowAcrossIndexShift() {
    let p = makeModel()
    p.move(4)
    XCTAssertEqual(p.selectedItem?.name, "fix/login-blank")
    p.inputModality = .pointer
    var input = WorktreePaletteSectionBuilder.Input.designSample
    input.localBranches.insert(GitBranch(name: "new", relativeDate: "now", upstream: nil), at: 0)
    rebuild(p, with: input)
    XCTAssertEqual(p.selected, 5, "行が 1 本増えた分だけ index がずれても同じ行を指す")
    XCTAssertEqual(p.selectedItem?.name, "fix/login-blank")
    XCTAssertEqual(p.inputModality, .pointer, "index がずれても裏の更新はモダリティを奪わない")
  }

  /// 選択していた行が差し替えで消えたら範囲内に収める。
  func testRestoreSelectionClampsWhenRowDisappears() {
    let p = makeModel()
    p.jump(1)
    XCTAssertEqual(p.selectedItem?.name, "origin/feat/fetch-progress", "末尾の remote branch 行")
    var input = WorktreePaletteSectionBuilder.Input.designSample
    input.remoteBranches = []
    rebuild(p, with: input)
    XCTAssertEqual(p.selected, 4, "消えた行の代わりに範囲内の末尾へ収める")
  }

  /// 選択をまだ動かしていなければ、データの到着でも今の worktree の行を選び直す（初回の一覧より後に
  /// 今の worktree が分かった場合も、その行が選ばれる）。
  func testUntouchedSelectionFollowsTheCurrentWorktreeAcrossRebuilds() {
    var input = WorktreePaletteSectionBuilder.Input.designSample
    input.currentWorktree = nil
    let p = makeModel(input)
    XCTAssertEqual(p.selected, 0)
    input.currentWorktree = NSHomeDirectory() + "/wt/pr-214"
    rebuild(p, with: input)
    XCTAssertEqual(p.selectedItem?.name, "pr-214")
  }

}
