import XCTest

@testable import Orbe

private typealias GitHub = TaskPaletteGitHubSamples

/// GitHub タブの右の欄（アサインするか・優先度・期限）のキーの流儀と値の寿命、agent の変更への追従。
///
/// 壊れると何が起きるか: 結び付いた行で欄に入れてしまい、使えない値を打たされる。期限の打ちかけが黙って
/// 消える、読めない期限のまま進む。別の行へ移っても前の行の優先度で作られる。逆に agent の変更だけで打った値が
/// 消える。agent が結び付けた行の欄に居残り、「タスクにする」が拒否される。
extension TaskPaletteModelTests {
  // MARK: - 右の欄

  /// → で入れるのは結び付いていない行だけ。チェックは足すものがある項目でだけ止まる。
  func testRightArrowEntersThePaneOnlyOnAnUnlinkedItem() {
    let palette = GitHub.model(
      [task(1, "a") { $0.links = [GitHub.link(7)] }],
      issues: [GitHub.issue(7), GitHub.issue(6), GitHub.issue(5, author: "me")])

    palette.enterPane()
    XCTAssertEqual(palette.area, .list, "結び付いている行")

    palette.move(1)
    palette.enterPane()
    XCTAssertEqual(palette.area, .pane(.assign))

    palette.leavePane()
    palette.move(1)
    palette.enterPane()
    XCTAssertEqual(palette.area, .pane(.priority), "自分が作成者の項目にはチェックが無い")
  }

  /// ↑↓ と優先度の ←→ は端で止まる。
  func testPaneStopsAndPriorityStopAtTheEnds() {
    let palette = GitHub.model([], issues: [GitHub.issue(5)])
    palette.enterPane()

    palette.movePaneStop(-1)
    XCTAssertEqual(palette.area, .pane(.assign))
    palette.movePaneStop(1)
    palette.changePaneValue(-1)
    palette.changePaneValue(-1)
    XCTAssertEqual(palette.pane.priority, .high)
    for _ in 0..<3 { palette.changePaneValue(1) }
    XCTAssertEqual(palette.pane.priority, .low)
    palette.movePaneStop(1)
    palette.movePaneStop(1)
    XCTAssertEqual(palette.area, .pane(.due))
  }

  /// 期限は 10/6・YYYY-MM-DD で読み、空なら期限なし、読めなければ理由を出して編集を続ける。
  func testPaneDueReadsShortDatesAndKeepsEditingUnreadableText() {
    let palette = GitHub.model([], issues: [GitHub.issue(5)])

    palette.beginPaneDue()
    palette.draftText = "10/6"
    XCTAssertTrue(palette.endEditing(commit: true))
    XCTAssertEqual(palette.pane.due, TaskItem.DueDate("2025-10-06"))

    palette.beginPaneDue()
    palette.draftText = "2025-12-01x"
    XCTAssertFalse(palette.endEditing(commit: true))
    XCTAssertEqual(palette.error, .due)
    XCTAssertEqual(palette.focusTarget, .paneDue, "打ちかけを残して編集を続ける")

    palette.draftText = ""
    XCTAssertTrue(palette.endEditing(commit: true))
    XCTAssertNil(palette.pane.due)
  }

  /// 選択の同一性が変わると欄の値は既定（オン・中・期限なし）に戻る。agent の変更で同じ行のままなら保つ。
  func testPaneValuesResetWhenTheSelectionMovesButSurviveAnAgentChange() throws {
    let palette = GitHub.model([], issues: [GitHub.issue(6), GitHub.issue(5)])
    palette.enterPane()
    palette.togglePaneAssign()
    palette.movePaneStop(1)
    palette.changePaneValue(-1)

    _ = try palette.store.add(TaskDraft(title: "agent が足した"))
    palette.reconcile()
    XCTAssertEqual(palette.pane.priority, .high)
    XCTAssertFalse(palette.pane.assignsSelf)

    palette.leavePane()
    palette.move(1)
    XCTAssertEqual(palette.pane.priority, .medium)
    XCTAssertTrue(palette.pane.assignsSelf)
    XCTAssertNil(palette.pane.due)
  }

  // MARK: - agent の変更への追従

  /// 開いている間に agent が結び付けると、その行は結び付いた側へ移り、選んだ行は同一性で保たれる。右の欄に
  /// 居た行が結び付いたら一覧へ戻る。
  func testAgentLinkingAnItemMovesItsRowAndKeepsTheSelectedItem() throws {
    let palette = GitHub.model(
      [task(1, "a")], issues: [GitHub.issue(7), GitHub.issue(6), GitHub.issue(5)])
    palette.move(1)
    palette.enterPane()

    var update = TaskUpdate()
    update.links = [GitHub.link(6), GitHub.link(5)]
    _ = try palette.store.update(1, update)
    palette.reconcile()

    XCTAssertEqual(
      palette.gitHubSelectableIDs, [.item(GitHub.id(6)), .item(GitHub.id(5)), .item(GitHub.id(7))])
    XCTAssertEqual(palette.selectedGitHubID, .item(GitHub.id(6)))
    XCTAssertEqual(palette.area, .list)
  }

  /// 一覧が伸びて上位 5 件が入れ替わり、選んでいた項目が「さらに」の内側へ押し出されても、その区分を開いて
  /// 選択をその項目に残す。
  func testSelectedItemPushedBehindMoreByANewPageExpandsItsSection() throws {
    let source = GitHub.Source()
    let palette = GitHub.model([], issues: (1...5).map { GitHub.issue($0) }, source: source)
    palette.tapGitHubRow(.item(GitHub.id(1)))

    palette.openLists.open(root: TaskPaletteSamples.root)
    try XCTUnwrap(source.fetches.first { $0.kind == .issue })
      .finish((1...10).reversed().map { GitHub.issue($0) })
    palette.reconcile()

    XCTAssertEqual(palette.expandedKinds, [.issue])
    XCTAssertEqual(palette.selectedGitHubID, .item(GitHub.id(1)))
  }

  /// 右の欄に居る間に、選んでいた項目が一覧の取り直しで消えたら一覧へ戻り、選択は同じ位置の項目へ移る。
  /// 打ちかけの期限は捨て、続く ↵ は一覧の ↵（入力欄）が受ける——別の項目の欄に既定の値で居続けると、↵ で
  /// 見ていない項目をタスクにして自分を足す。
  func testLeavingThePaneWhenTheSelectedItemLeavesTheList() throws {
    let source = GitHub.Source()
    let palette = GitHub.model(
      [], issues: [GitHub.issue(7), GitHub.issue(6), GitHub.issue(5)], source: source)
    palette.move(1)
    palette.enterPane()
    palette.beginPaneDue()
    palette.draftText = "10/"

    palette.openLists.open(root: TaskPaletteSamples.root)
    try XCTUnwrap(source.fetches.first { $0.kind == .issue })
      .finish([GitHub.issue(7), GitHub.issue(5)])
    palette.reconcile()

    XCTAssertEqual(palette.area, .list)
    XCTAssertEqual(palette.selectedGitHubID, .item(GitHub.id(5)))
    XCTAssertNil(palette.draft)
    XCTAssertEqual(palette.focusTarget, .field)
    XCTAssertEqual(palette.pane, TaskGitHubPane(owner: .item(GitHub.id(5))))
  }
}
