import XCTest

@testable import Orbe

/// Dispatch パレット（DispatchPaletteModel）のロジック検証。libghostty 非依存（@Observable モデルのみ）。
/// live git/gh は叩かず `DispatchSectionBuilder` に mock 入力を通してセクションを組む。
@MainActor
final class DispatchPaletteTests: XCTestCase {

  private func makeModel(
    _ input: DispatchSectionBuilder.Input = .designSample,
    agents: [AgentCLI] = [
      AgentCLI(command: "claude", path: "/bin/claude"),
      AgentCLI(command: "codex", path: "/bin/codex"),
    ]
  ) -> DispatchPaletteModel {
    let model = DispatchPaletteModel()
    model.setTargets(agents: agents, defaultCommand: "claude")
    model.githubState = input.githubState
    model.sections = DispatchSectionBuilder.build(input)
    model.clampSelection()
    return model
  }

  func testSampleShape() {
    let p = makeModel()
    XCTAssertEqual(p.sections.count, 5, "Worktrees/Local/Remote/Issues/PR の 5 セクション")
    XCTAssertEqual(p.items.count, 8, "対話行は全 8 行（セクション横断の平坦数）")
    XCTAssertEqual(p.selected, 0)
    XCTAssertEqual(p.selectedItem?.name, "agent-hooks", "初期選択は先頭 worktree")
    XCTAssertTrue(p.selectedItem?.isPrimary ?? false, "先頭 worktree はアクティブ（強調）")
  }

  func testMoveWrapsAcrossSections() {
    let p = makeModel()
    p.move(-1)
    XCTAssertEqual(p.selected, 7, "先頭で上 → 末尾へ wrap")
    XCTAssertEqual(p.selectedItem?.name, "feat: session restore", "末尾は PR 行")
    p.move(1)
    XCTAssertEqual(p.selected, 0, "末尾から下 → 先頭へ wrap")
  }

  func testFilterNarrowsAcrossSectionsAndDropsEmpty() {
    let p = makeModel()
    p.query = "feat"
    p.onQueryChanged()
    XCTAssertEqual(
      p.visibleSections.map(\.title), ["Worktrees", "Remote branches", "Pull requests"],
      "マッチの無い Local branches / Issues セクションは消える")
    XCTAssertEqual(p.items.count, 3, "feat を含む 3 行だけ残る")
    XCTAssertEqual(p.selected, 0, "選択は先頭の可視行へクランプ")
    XCTAssertEqual(p.selectedItem?.name, "agent-hooks")
  }

  func testFilterMatchesIdAndDetail() {
    let p = makeModel()
    p.query = "#145"
    p.onQueryChanged()
    XCTAssertEqual(p.items.count, 1, "idText の #145 に PR 行がマッチ")
    XCTAssertEqual(p.selectedItem?.name, "feat: session restore")
  }

  func testMoveSkipsInfoRows() {
    var input = DispatchSectionBuilder.Input.designSample
    input.issues = []
    input.pullRequests = []
    input.githubState = .ghMissing
    let p = makeModel(input)
    // 対話行 5（worktree2＋local2＋remote1）＋Issues 誘導情報行 1。
    XCTAssertEqual(p.items.count, 6)
    XCTAssertFalse(p.items.last?.isInteractive ?? true, "末尾は非対話の誘導情報行")
    p.selected = 4  // 末尾の対話行（remote）
    p.move(1)
    XCTAssertEqual(p.selected, 0, "情報行を飛ばして先頭へ wrap")
    XCTAssertTrue(p.selectedItem?.isInteractive ?? false)
  }

  func testJumpSkipsInfoRows() {
    var input = DispatchSectionBuilder.Input.designSample
    input.issues = []
    input.pullRequests = []
    input.githubState = .ghMissing
    let p = makeModel(input)
    XCTAssertEqual(p.items.count, 6)
    XCTAssertFalse(p.items.last?.isInteractive ?? true, "末尾は非対話の誘導情報行")
    p.jump(1)
    XCTAssertEqual(p.selected, 4, "⌘↓＝情報行を飛ばして末尾の対話行へ")
    XCTAssertTrue(p.selectedItem?.isInteractive ?? false)
    p.jump(-1)
    XCTAssertEqual(p.selected, 0, "⌘↑＝先頭の対話行へ")
    XCTAssertTrue(p.selectedItem?.isInteractive ?? false)
  }

  func testCycleTarget() {
    // agents=[claude,codex]・default=claude → targets=[claude, shell, codex]、初期選択は claude。
    let p = makeModel()
    XCTAssertEqual(p.selectedTargetName, "claude", "初期選択は default agent")
    p.cycleTarget()
    XCTAssertEqual(p.selectedTargetName, "shell", "⇥ 一回で default agent 直後の shell へ")
    p.cycleTarget()
    XCTAssertEqual(p.selectedTargetName, "codex")
    p.cycleTarget()
    XCTAssertEqual(p.selectedTargetName, "claude", "巡回は端で wrap")
  }

  func testShellSelectableWithoutAgents() {
    // agent 未検出でも targets は必ず shell を含み、それが選択される（袋小路の解消）。
    let p = makeModel(agents: [])
    XCTAssertEqual(p.selectedTarget, .shell, "agent 未検出でも shell が選べる")
    XCTAssertEqual(p.selectedTargetName, "shell")
    p.cycleTarget()
    XCTAssertEqual(p.selectedTarget, .shell, "shell 一択の巡回は shell のまま")
  }

  func testSetTargetsSplicesShellAfterDefaultAndSelectsDefault() {
    // 本 PR の中核: shell は「default agent の直後」に挿入し、初期選択は default agent。
    // default が非先頭（実ユーザーが default を codex に設定した場合）でも連動することを固定する。
    let codex = AgentCLI(command: "codex", path: "/bin/codex")
    let claude = AgentCLI(command: "claude", path: "/bin/claude")
    let p = DispatchPaletteModel()
    p.setTargets(agents: [codex, claude], defaultCommand: "codex")
    XCTAssertEqual(
      p.targets, [.agent(codex), .shell, .agent(claude)], "shell は default(codex) の直後に挿入")
    XCTAssertEqual(p.selectedTargetName, "codex", "初期選択は default agent（先頭でなくても）")
  }

  func testSetTargetsFallsBackToFirstWhenDefaultAbsent() {
    // default が agents に無ければ先頭 agent を初期選択（?? 0 分岐）。
    let p = DispatchPaletteModel()
    p.setTargets(
      agents: [
        AgentCLI(command: "codex", path: "/bin/codex"),
        AgentCLI(command: "claude", path: "/bin/claude"),
      ], defaultCommand: "missing")
    XCTAssertEqual(p.selectedTargetName, "codex", "default 不在なら先頭 agent へフォールバック")
  }

  func testCanOpenWebOnlyForIssueAndPR() {
    let p = makeModel()
    let byName = Dictionary(p.items.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    XCTAssertEqual(
      byName["Status detection doesn't work inside tmux"]?.canOpenWeb, true, "issue は開ける")
    XCTAssertEqual(byName["feat: session restore"]?.canOpenWeb, true, "PR は開ける")
    XCTAssertEqual(byName["agent-hooks"]?.canOpenWeb, false, "worktree は開けない")
    XCTAssertEqual(byName["main"]?.canOpenWeb, false, "branch は開けない")
  }

  func testCanOpenWebForPRLinkedBranch() {
    let p = makeModel()
    let byName = Dictionary(p.items.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    // designSample の remote branch origin/feat/session-restore は PR #145 に紐づく。
    let linked = byName["origin/feat/session-restore"]
    XCTAssertEqual(linked?.linkedPRNumber, 145)
    XCTAssertEqual(linked?.canOpenWeb, true, "PR に紐づく remote branch 行は開ける")
  }

  func testExecuteAndOpenWebWiring() {
    let p = makeModel()
    var executed: DispatchItem?
    var opened: DispatchItem?
    p.onExecute = { executed = $0 }
    p.onOpenWeb = { opened = $0 }
    p.selected = 5  // issue #151
    p.activate()  // ↵ の決定経路
    p.onOpenWeb(p.selectedItem!)
    XCTAssertEqual(executed?.name, "Status detection doesn't work inside tmux")
    XCTAssertEqual(opened?.name, "Status detection doesn't work inside tmux")
  }

  /// 行タップは ↵ と同じ決定 funnel を通り、選択をその行へ移したうえで同じ行を実行する。
  func testActivateAtRowSelectsAndExecutesSameRow() {
    let p = makeModel()
    var executed: [String] = []
    p.onExecute = { executed.append($0.name) }
    p.activate(at: 5)  // issue #151 の行をタップ
    XCTAssertEqual(p.selected, 5, "タップで選択もその行へ移る")
    XCTAssertEqual(executed, ["Status detection doesn't work inside tmux"])

    // ↵（選択行の決定）と同一の結果になる＝クリック用の別経路を持たない。
    var byEnter: [String] = []
    p.onExecute = { byEnter.append($0.name) }
    p.activate()
    XCTAssertEqual(byEnter, executed)
  }

  /// 非対話行（gh 誘導情報・ローディング）のタップでは実行しない。
  func testActivateIgnoresNonInteractiveRow() {
    var input = DispatchSectionBuilder.Input.designSample
    input.issues = []
    input.pullRequests = []
    input.githubState = .ghMissing
    let p = makeModel(input)
    var executed = 0
    p.onExecute = { _ in executed += 1 }
    XCTAssertFalse(p.items.last?.isInteractive ?? true)
    p.activate(at: p.items.count - 1)
    XCTAssertEqual(executed, 0, "情報行は決定の対象外")
    XCTAssertEqual(p.selected, 0, "選択も動かさない")
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

  func testDismissWiring() {
    let p = makeModel()
    var dismissed = false
    p.onDismiss = { dismissed = true }
    p.onDismiss()
    XCTAssertTrue(dismissed)
  }

  func testFocusAdvancesToken() {
    let p = makeModel()
    let before = p.focusToken
    p.focus()
    XCTAssertEqual(p.focusToken, before &+ 1)
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

  /// 初期は `.keyboard`。キー移動中はスクロールで行がカーソル下へ来ても選択を奪われない。
  func testHoverSuppressedDuringKeyboardModality() {
    let p = makeModel()
    p.hoverSelect(3)
    XCTAssertEqual(p.selected, 0, "実マウス移動前は追従しない")
    p.inputModality = .pointer
    p.move(1)
    p.hoverSelect(3)
    XCTAssertEqual(p.selected, 1, "キー移動で .keyboard へ戻り、ホバーに奪われない")
  }

  /// 絞り込み打鍵などモデルが選択を直接置く経路も `.keyboard` へ戻す。
  func testHoverSuppressedAfterQueryChange() {
    let p = makeModel()
    p.inputModality = .pointer
    p.query = "feat"
    p.onQueryChanged()
    p.hoverSelect(2)
    XCTAssertEqual(p.selected, 0, "打鍵後は実マウス移動があるまで追従しない")
  }

  // MARK: - 選択復元（裏の gh 更新による sections 差し替え）

  /// provider の rebuild と同じ手順（選択 action を控える → sections 差し替え → 復元）。
  private func rebuild(_ p: DispatchPaletteModel, with input: DispatchSectionBuilder.Input) {
    let action = p.selectedItem?.action
    p.sections = DispatchSectionBuilder.build(input)
    p.restoreSelection(matching: action)
  }

  /// Issues が増えて index がずれても、選択は同じ issue 行に追従する。
  func testRestoreSelectionFollowsRowAcrossIndexShift() {
    let p = makeModel()
    p.selected = 6
    XCTAssertEqual(p.selectedItem?.name, "Tab drag order isn't persisted")
    p.inputModality = .pointer
    var input = DispatchSectionBuilder.Input.designSample
    input.issues.insert(GitHubIssue(number: 160, title: "New issue"), at: 0)
    rebuild(p, with: input)
    XCTAssertEqual(p.selected, 7, "行が 1 本増えた分だけ index がずれても同じ行を指す")
    XCTAssertEqual(p.selectedItem?.name, "Tab drag order isn't persisted")
    XCTAssertEqual(p.inputModality, .pointer, "index がずれても裏の更新はモダリティを奪わない")
  }

  /// 選択していた行が差し替えで消えたら clamp（範囲内の対話行）に落ちる。
  func testRestoreSelectionClampsWhenRowDisappears() {
    let p = makeModel()
    p.selected = 7
    XCTAssertEqual(p.selectedItem?.name, "feat: session restore", "末尾の PR 行")
    var input = DispatchSectionBuilder.Input.designSample
    input.pullRequests = []
    rebuild(p, with: input)
    XCTAssertEqual(p.selected, 6, "消えた行の代わりに範囲内の末尾へ clamp")
    XCTAssertTrue(p.selectedItem?.isInteractive ?? false)
  }

  /// 非対話行を選んでいた（action == nil）ときは従来どおり clamp する。
  func testRestoreSelectionClampsForNonInteractiveRow() {
    var input = DispatchSectionBuilder.Input.designSample
    input.issues = []
    input.pullRequests = []
    input.githubState = .ghMissing
    let p = makeModel(input)
    p.selected = 5
    XCTAssertNil(p.selectedItem?.action, "誘導情報行は action を持たない")
    rebuild(p, with: input)
    XCTAssertEqual(p.selected, 0, "非対話行のままにせず先頭の対話行へ clamp")
    XCTAssertTrue(p.selectedItem?.isInteractive ?? false)
  }

  /// index が変わらない復元では代入せず、ホバー追従（`.pointer`）を殺さない。
  func testRestoreSelectionKeepsPointerModalityWhenIndexUnchanged() {
    let p = makeModel()
    p.inputModality = .pointer
    rebuild(p, with: .designSample)
    XCTAssertEqual(p.selected, 0)
    XCTAssertEqual(p.inputModality, .pointer, "裏の更新はモダリティを奪わない")
  }

  /// 非対話行（gh 誘導情報・ローディング）と範囲外・作成中では追従しない。
  func testHoverIgnoresNonInteractiveAndBlockedStates() {
    var input = DispatchSectionBuilder.Input.designSample
    input.issues = []
    input.pullRequests = []
    input.githubState = .ghMissing
    let p = makeModel(input)
    p.inputModality = .pointer
    XCTAssertFalse(p.items.last?.isInteractive ?? true, "末尾は非対話の誘導情報行")
    p.hoverSelect(p.items.count - 1)
    XCTAssertEqual(p.selected, 0, "情報行はホバー追従の対象外")
    p.hoverSelect(99)
    XCTAssertEqual(p.selected, 0, "範囲外は no-op")
    p.isPreparing = true
    p.hoverSelect(2)
    XCTAssertEqual(p.selected, 0, "作成中はキー操作と同様に受け付けない")
  }
}
