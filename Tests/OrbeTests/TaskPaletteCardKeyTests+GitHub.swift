import AppKit
import XCTest

@testable import Orbe

private typealias GitHub = TaskPaletteGitHubSamples

/// GitHub タブ・右の欄・選ぶ状態のキーと、一覧の置き場の変化をカードが付け直しへ届ける配線。
///
/// 壊れると何が起きるか: 絞り込みに「l」を打つと結び付けが始まる、入力を消す ⌫ が結び付きを外す。押し続けた
/// ⌘⌫・↵ が、押した行の先まで外す・タスクにする（未確認の項目に自分をアサインする）。⇥ が絞り込みでなく範囲を
/// 切り替える。選ぶ状態の esc で画面ごと閉じる。項目を選ぶ間の ⌘⌫ で、別のタスクの結び付きが外れる。右の欄の
/// 期限で打った日付が絞り込みに入る、期限の ↵ でタスクができる。一覧が取り直されて行が消えても、消えた行を
/// 選んだまま ↵ が空振りする。
extension TaskPaletteCardKeyTests {
  private enum GitHubKey {
    static let l: UInt16 = 37
  }

  /// ⌘L は入力欄に文字があっても結び付けを始め、入力は変えない。素の l・L は文字として入る。
  func testCommandLStartsLinkingAndPlainLTypes() {
    let model = GitHub.model([TaskPaletteSamples.task(1, "a")], issues: [GitHub.issue(5)])
    let window = mount(model)

    press(GitHubKey.l, "l", to: window)
    press(GitHubKey.l, "L", .shift, to: window)
    XCTAssertEqual(model.query, "lL")
    XCTAssertNil(model.pick)

    model.query = ""
    flush(window)
    type("5", into: window)
    XCTAssertEqual(model.query, "5", "前提")
    press(GitHubKey.l, "l", .command, to: window)
    XCTAssertNotNil(model.pick)
    XCTAssertEqual(model.visibleTab, .tasks)
    model.cancelPick()
    XCTAssertEqual(model.query, "5", "GitHub タブの入力は変えない")
  }

  /// 右の欄でも ⌘L で結び付けを始める。
  func testCommandLInThePaneStartsLinking() {
    let model = GitHub.model([TaskPaletteSamples.task(1, "a")], issues: [GitHub.issue(5)])
    let window = mount(model)
    arrow(Key.right, to: window)
    XCTAssertEqual(model.area, .pane(.assign), "前提: 右の欄")

    press(GitHubKey.l, "l", .command, to: window)

    XCTAssertNotNil(model.pick)
  }

  /// ⌘⌫ は入力欄に文字があっても結び付きを外す。素の ⌫ は、空の入力欄でも外さない。
  func testCommandBackspaceUnlinksAndPlainBackspaceNeverDoes() {
    let model = GitHub.model(
      [TaskPaletteSamples.task(1, "a") { $0.links = [GitHub.link(6), GitHub.link(5)] }],
      issues: [GitHub.issue(6), GitHub.issue(5)])
    let window = mount(model)

    press(Key.delete, "\u{7F}", to: window)
    press(Key.delete, "\u{7F}", repeating: true, to: window)
    XCTAssertEqual(model.store.tasks.first?.links.count, 2, "素の ⌫ は外さない")

    type("6", into: window)
    press(Key.delete, "\u{7F}", .command, to: window)

    XCTAssertEqual(model.store.tasks.first?.links, [GitHub.link(5)])
    XCTAssertEqual(model.query, "6", "⌘⌫ は入力を消さない")
  }

  /// ⌘⌫ のキーリピートでは外さない（押し始めが別の場所で、リピートだけが届いても）。
  func testCommandBackspaceKeyRepeatDoesNotUnlink() {
    let model = GitHub.model(
      [TaskPaletteSamples.task(1, "a") { $0.links = [GitHub.link(5)] }], issues: [GitHub.issue(5)])
    let window = mount(model)

    press(Key.delete, "\u{7F}", .command, repeating: true, to: window)
    press(Key.delete, "\u{7F}", .command, repeating: true, to: window)

    XCTAssertEqual(model.store.tasks.first?.links, [GitHub.link(5)])
  }

  /// 選ぶ状態の間は、⌘L・⌘⌫ とも何もしない。
  func testCommandLAndCommandBackspaceDoNothingWhilePicking() {
    let model = GitHub.model(
      [
        TaskPaletteSamples.task(1, "a"),
        TaskPaletteSamples.task(2, "b") { $0.links = [GitHub.link(5)] },
      ], issues: [GitHub.issue(5)])
    model.setTab(.tasks)
    model.area = .detail(.addLink)
    model.beginPickingItem()
    let window = mount(model)
    XCTAssertEqual(model.selectedGitHubID, .item(GitHub.id(5)), "前提: 別のタスクの結び付いた行")

    press(Key.delete, "\u{7F}", .command, to: window)
    press(GitHubKey.l, "l", .command, to: window)

    XCTAssertEqual(model.store.tasks.last?.links, [GitHub.link(5)])
    XCTAssertEqual(model.visibleTab, .github, "タスクを選ぶ状態へ移らない")
  }

  /// GitHub タブの ⇥ は絞り込みの札を巡回し、範囲は変えない。
  func testTabCyclesTheFilterOnTheGitHubTab() {
    let model = GitHub.model([], issues: [GitHub.issue(5)])
    let window = mount(model)

    press(Key.tab, "\t", to: window)

    XCTAssertEqual(model.githubFilter, .assigned)
    XCTAssertEqual(model.scope, .all)
  }

  /// → で右の欄へ入り、space でチェックを切り替え、← で一覧へ戻る。
  func testArrowKeysEnterAndLeaveThePaneAndSpaceTogglesTheCheck() {
    let model = GitHub.model([], issues: [GitHub.issue(5)])
    let window = mount(model)

    arrow(Key.right, to: window)
    XCTAssertEqual(model.area, .pane(.assign))
    press(Key.space, " ", to: window)
    XCTAssertFalse(model.pane.assignsSelf)
    arrow(Key.left, to: window)

    XCTAssertEqual(model.area, .list)
    XCTAssertEqual(model.query, "", "space は入力欄へ入らない")
  }

  /// 選ぶ状態の esc は、画面を閉じずに選ぶ状態をやめる（タスクを選ぶ・項目を選ぶの両方）。
  func testEscapeWhilePickingCancelsInsteadOfDismissing() {
    let model = GitHub.model([TaskPaletteSamples.task(1, "a")], issues: [GitHub.issue(5)])
    var dismissed = false
    model.onDismiss = { dismissed = true }
    let window = mount(model)

    press(GitHubKey.l, "l", .command, to: window)
    press(Key.escape, "\u{1B}", to: window)
    XCTAssertNil(model.pick)
    XCTAssertEqual(model.visibleTab, .github)

    model.setTab(.tasks)
    model.area = .detail(.addLink)
    model.beginPickingItem()
    flush(window)
    press(Key.escape, "\u{1B}", to: window)
    XCTAssertNil(model.pick)
    XCTAssertEqual(model.area, .detail(.addLink))

    XCTAssertFalse(dismissed)
  }

  /// 一覧が取り直されて選んだ行が消えたら、カードが付け直し、同じ位置の行を選ぶ。
  func testListRefetchRemovingTheSelectedRowMovesTheSelection() throws {
    let source = GitHub.Source()
    let model = GitHub.model(
      [], issues: [GitHub.issue(7), GitHub.issue(6), GitHub.issue(5)], source: source)
    _ = mount(model)
    model.move(1)

    model.openLists.open(root: TaskPaletteSamples.root)
    try XCTUnwrap(source.fetches.first { $0.kind == .issue })
      .finish([GitHub.issue(7), GitHub.issue(5)])
    pump(0.3)

    XCTAssertEqual(model.selectedGitHubID, .item(GitHub.id(5)))
  }

  // MARK: - ブラウザで開く（⌘↵）

  /// 一覧でも右の欄でも、⌘↵ は選んでいる項目の GitHub のページをブラウザで開く（結び付きの有無を問わない）。
  /// タスクにはしない。
  func testCommandEnterOpensTheSelectedItemInTheBrowserFromTheListAndThePane() {
    let model = GitHub.model(
      [TaskPaletteSamples.task(1, "a") { $0.links = [GitHub.link(6)] }],
      issues: [GitHub.issue(6), GitHub.issue(5)], pullRequests: [GitHub.pullRequest(9)])
    var opened: [String] = []
    model.onOpenURL = { opened.append($0.absoluteString) }
    let window = mount(model)

    for id in [GitHub.id(6), GitHub.id(5), GitHub.id(9)] {
      model.tapGitHubRow(.item(id))
      flush(window)
      press(Key.enter, "\r", .command, to: window)
    }
    arrow(Key.right, to: window)
    XCTAssertEqual(model.area, .pane(.assign), "前提: 結び付いていない PR の右の欄")
    press(Key.enter, "\r", .command, to: window)

    XCTAssertEqual(
      opened,
      [
        "https://github.com/o/n/issues/6", "https://github.com/o/n/issues/5",
        "https://github.com/o/n/pull/9", "https://github.com/o/n/pull/9",
      ])
    XCTAssertEqual(model.store.tasks.count, 1, "タスクにしない")
  }

  /// 結び付ける項目を選ぶ間の ⌘↵ は、開きもせず、↵ の結び付けとしても働かない。
  func testCommandEnterWhilePickingAnItemNeitherOpensNorLinks() {
    let model = GitHub.model([TaskPaletteSamples.task(1, "a")], issues: [GitHub.issue(5)])
    var opened: [URL] = []
    model.onOpenURL = { opened.append($0) }
    model.setTab(.tasks)
    model.area = .detail(.addLink)
    model.beginPickingItem()
    let window = mount(model)
    XCTAssertEqual(model.selectedGitHubID, .item(GitHub.id(5)), "前提: 項目を選ぶ状態")

    press(Key.enter, "\r", .command, to: window)

    XCTAssertEqual(opened, [])
    XCTAssertEqual(model.store.tasks.first?.links, [])
    XCTAssertNotNil(model.pick)
  }

  /// 右の欄の期限を打っている間の ⌘↵ は、打った期限の確定で、ブラウザでは開かない。
  func testCommandEnterWhileTypingThePaneDueCommitsIt() {
    let model = GitHub.model([], issues: [GitHub.issue(5)])
    var opened: [URL] = []
    model.onOpenURL = { opened.append($0) }
    let window = mount(model)
    arrow(Key.right, to: window)
    arrow(Key.down, to: window)
    arrow(Key.down, to: window)
    press(Key.enter, "\r", to: window)
    type("10/6", into: window)

    press(Key.enter, "\r", .command, to: window)

    XCTAssertEqual(model.pane.due, TaskItem.DueDate("2025-10-06"))
    XCTAssertNil(model.draft)
    XCTAssertEqual(opened, [])
  }

  // MARK: - 押し続けた ↵

  /// 「さらに」で ↵ を押し続けても、区分が開くだけでタスクは増えない（出てきた項目に自分を足さない）。
  func testEnterHeldOnMoreOnlyExpandsTheSection() {
    let source = GitHub.Source()
    let model = GitHub.model([], issues: (1...7).map { GitHub.issue($0) }, source: source)
    let window = mount(model)
    model.jump(1)
    XCTAssertEqual(model.selectedGitHubID, .more(.issue), "前提: さらに")

    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)
    press(Key.enter, "\r", repeating: true, to: window)

    XCTAssertEqual(model.expandedKinds, [.issue])
    XCTAssertTrue(model.store.tasks.isEmpty)
    XCTAssertTrue(source.writes.isEmpty)
  }

  /// タスクのタブで ↵ を押し続けても、完了になるのは押した 1 件だけ。
  func testEnterHeldOnTheTasksTabCompletesOneTask() {
    let model = model()
    let window = mount(model)

    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)
    press(Key.enter, "\r", repeating: true, to: window)

    XCTAssertEqual(model.store.tasks.map(\.status), [.done, .todo, .todo])
  }

  // MARK: - 選ぶ状態の space

  /// 結び付けるタスクを選ぶ間、空の入力欄の space は何もしない（完了にせず、空白も入れない）。
  func testSpaceWhilePickingATaskDoesNothing() {
    let model = GitHub.model([TaskPaletteSamples.task(1, "a")], issues: [GitHub.issue(5)])
    let window = mount(model)
    press(GitHubKey.l, "l", .command, to: window)
    XCTAssertNotNil(model.pick, "前提: タスクを選ぶ状態")

    press(Key.space, " ", to: window)

    XCTAssertEqual(model.query, "")
    XCTAssertEqual(status(model, 1), .todo)
  }

  // MARK: - 右の欄の期限

  /// 期限の ↵ で打ち始め、打った文字は絞り込みに入らず、↵ で欄の値になる。優先度へ移った ↵ はタスクにする。
  func testPaneDueIsTypedWithEnterAndEnterElsewhereMakesTheTask() throws {
    let model = GitHub.model([], issues: [GitHub.issue(5)])
    let window = mount(model)
    arrow(Key.right, to: window)
    arrow(Key.down, to: window)
    arrow(Key.down, to: window)
    XCTAssertEqual(model.area, .pane(.due), "前提: 期限")

    press(Key.enter, "\r", to: window)
    XCTAssertTrue(model.store.tasks.isEmpty, "期限の ↵ はタスクにしない")
    type("10/6", into: window)
    XCTAssertEqual(model.query, "", "打った文字は絞り込みに入らない")
    press(Key.enter, "\r", to: window)
    XCTAssertEqual(model.pane.due, TaskItem.DueDate("2025-10-06"))
    XCTAssertNil(model.draft)

    arrow(Key.up, to: window)
    press(Key.enter, "\r", to: window)

    let made = try XCTUnwrap(model.store.tasks.first)
    XCTAssertEqual(made.due, TaskItem.DueDate("2025-10-06"))
    XCTAssertEqual(made.links, [GitHub.link(5)])
  }
}
