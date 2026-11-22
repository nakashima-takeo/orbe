import SwiftUI
import XCTest

@testable import Orbe

private typealias GitHub = TaskPaletteGitHubSamples

/// GitHub タブ・右の欄・選ぶ状態のキー。
extension TaskPaletteKeyTests {
  /// 右の欄でも ⌘L で結び付けを始める。
  func testCommandLInThePaneStartsLinking() {
    let model = GitHub.model([TaskPaletteSamples.task(1, "a")], issues: [GitHub.issue(5)])
    send(.rightArrow, to: model)
    XCTAssertEqual(model.area, .pane(.assign), "前提: 右の欄")

    send("l", .command, to: model)

    XCTAssertNotNil(model.pick)
  }

  /// ⌘⌫ は入力欄に文字があっても結び付きを外す。素の ⌫ は、空の入力欄でも外さない。
  func testCommandBackspaceUnlinksAndPlainBackspaceNeverDoes() {
    let model = GitHub.model(
      [TaskPaletteSamples.task(1, "a") { $0.links = [GitHub.link(6), GitHub.link(5)] }],
      issues: [GitHub.issue(6), GitHub.issue(5)])

    send(.backspace, to: model, expect: .ignored)
    send(.backspace, repeating: true, to: model, expect: .ignored)
    XCTAssertEqual(model.store.tasks.first?.links.count, 2, "素の ⌫ は外さない")

    model.query = "6"
    send(.backspace, .command, to: model)

    XCTAssertEqual(model.store.tasks.first?.links, [GitHub.link(5)])
    XCTAssertEqual(model.query, "6", "⌘⌫ は入力を消さない")
  }

  /// ⌘⌫ のキーリピートでは外さない（押し始めが別の場所で、リピートだけが届いても）。
  func testCommandBackspaceKeyRepeatDoesNotUnlink() {
    let model = GitHub.model(
      [TaskPaletteSamples.task(1, "a") { $0.links = [GitHub.link(5)] }], issues: [GitHub.issue(5)])

    send(.backspace, .command, repeating: true, to: model, expect: .ignored)
    send(.backspace, .command, repeating: true, to: model, expect: .ignored)

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
    XCTAssertEqual(model.selectedGitHubID, .item(GitHub.id(5)), "前提: 別のタスクの結び付いた行")

    send(.backspace, .command, to: model)
    send("l", .command, to: model)

    XCTAssertEqual(model.store.tasks.last?.links, [GitHub.link(5)])
    XCTAssertEqual(model.visibleTab, .github, "タスクを選ぶ状態へ移らない")
  }

  /// GitHub タブの ⇥ は次のタブへ移り、絞り込みの札は変えない。
  func testTabMovesToTheNextTabOnTheGitHubTab() {
    let model = GitHub.model([], issues: [GitHub.issue(5)])

    send(.tab, to: model)

    XCTAssertEqual(model.tab, .automation)
    XCTAssertEqual(model.githubFilters, [])
  }

  /// → で右の欄へ入り、space でチェックを切り替え、← で一覧へ戻る。
  func testArrowKeysEnterAndLeaveThePaneAndSpaceTogglesTheCheck() {
    let model = GitHub.model([], issues: [GitHub.issue(5)])

    send(.rightArrow, to: model)
    XCTAssertEqual(model.area, .pane(.assign))
    send(.space, to: model)
    XCTAssertFalse(model.pane.assignsSelf)
    send(.leftArrow, to: model)

    XCTAssertEqual(model.area, .list)
    XCTAssertEqual(model.query, "", "space は入力欄へ入らない")
  }

  /// 選ぶ状態の esc は、画面を閉じずに選ぶ状態をやめる（タスクを選ぶ・項目を選ぶの両方）。
  func testEscapeWhilePickingCancelsInsteadOfDismissing() {
    let model = GitHub.model([TaskPaletteSamples.task(1, "a")], issues: [GitHub.issue(5)])
    var dismissed = false
    model.onDismiss = { dismissed = true }

    send("l", .command, to: model)
    send(.escape, to: model)
    XCTAssertNil(model.pick)
    XCTAssertEqual(model.visibleTab, .github)

    model.setTab(.tasks)
    model.area = .detail(.addLink)
    model.beginPickingItem()
    send(.escape, to: model)
    XCTAssertNil(model.pick)
    XCTAssertEqual(model.area, .detail(.addLink))

    XCTAssertFalse(dismissed)
  }

  // MARK: - タスクにして開く（⌘↵）

  /// 一覧でも右の欄でも、⌘↵ は結び付いていない項目をタスクにしてからそのタスクで、結び付いている項目はそのタスクで
  /// agent を開く。ブラウザでは開かない。
  func testCommandEnterOpensTheSelectedItemAsATaskFromTheListAndThePane() throws {
    let model = GitHub.model(
      [TaskPaletteSamples.task(1, "a") { $0.links = [GitHub.link(6)] }],
      issues: [GitHub.issue(6), GitHub.issue(5)], pullRequests: [GitHub.pullRequest(9)])
    var opened: [Int] = []
    var browsed: [URL] = []
    model.onOpenWorktreePalette = { opened.append($0) }
    model.onOpenURL = { browsed.append($0) }

    for id in [GitHub.id(6), GitHub.id(5)] {
      model.tapGitHubRow(.item(id))
      send(.return, .command, to: model)
    }
    model.tapGitHubRow(.item(GitHub.id(9)))
    send(.rightArrow, to: model)
    XCTAssertEqual(model.area, .pane(.assign), "前提: 結び付いていない PR の右の欄")
    send(.return, .command, to: model)

    let issueTask = try XCTUnwrap(
      model.store.tasks.first { $0.links.map(\.item) == [GitHub.id(5)] })
    let prTask = try XCTUnwrap(model.store.tasks.first { $0.links.map(\.item) == [GitHub.id(9)] })
    XCTAssertEqual(opened, [1, issueTask.id, prTask.id])
    XCTAssertEqual(model.store.tasks.count, 3, "結び付いている項目はタスクを足さない")
    XCTAssertEqual(browsed, [])
  }

  // MARK: - ブラウザで開く（⌘O）

  /// 一覧でも右の欄でも、⌘O は選んでいる項目の GitHub のページをブラウザで開く（結び付きの有無を問わない）。
  /// タスクにはしない。
  func testCommandOOpensTheSelectedItemInTheBrowserFromTheListAndThePane() {
    let model = GitHub.model(
      [TaskPaletteSamples.task(1, "a") { $0.links = [GitHub.link(6)] }],
      issues: [GitHub.issue(6), GitHub.issue(5)], pullRequests: [GitHub.pullRequest(9)])
    var opened: [String] = []
    model.onOpenURL = { opened.append($0.absoluteString) }

    for id in [GitHub.id(6), GitHub.id(5), GitHub.id(9)] {
      model.tapGitHubRow(.item(id))
      send("o", .command, to: model)
    }
    send(.rightArrow, to: model)
    XCTAssertEqual(model.area, .pane(.assign), "前提: 結び付いていない PR の右の欄")
    send("o", .command, to: model)

    XCTAssertEqual(
      opened,
      [
        "https://github.com/o/n/issues/6", "https://github.com/o/n/issues/5",
        "https://github.com/o/n/pull/9", "https://github.com/o/n/pull/9",
      ])
    XCTAssertEqual(model.store.tasks.count, 1, "タスクにしない")
  }

  /// 結び付ける項目を選ぶ間の ⌘↵・⌘O は、タスクにも開きもせず、↵ の結び付けとしても働かない。
  func testCommandEnterAndCommandOWhilePickingAnItemNeitherOpenNorLink() {
    let model = GitHub.model([TaskPaletteSamples.task(1, "a")], issues: [GitHub.issue(5)])
    var opened: [URL] = []
    var openedTasks: [Int] = []
    model.onOpenURL = { opened.append($0) }
    model.onOpenWorktreePalette = { openedTasks.append($0) }
    model.setTab(.tasks)
    model.area = .detail(.addLink)
    model.beginPickingItem()
    XCTAssertEqual(model.selectedGitHubID, .item(GitHub.id(5)), "前提: 項目を選ぶ状態")

    send(.return, .command, to: model)
    send("o", .command, to: model)

    XCTAssertEqual(opened, [])
    XCTAssertEqual(openedTasks, [])
    XCTAssertEqual(model.store.tasks.count, 1)
    XCTAssertEqual(model.store.tasks.first?.links, [])
    XCTAssertNotNil(model.pick)
  }

  /// 右の欄の期限を打っている間の ⌘↵ は、打った期限の確定で、タスクにして開かない。
  func testCommandEnterWhileTypingThePaneDueCommitsIt() {
    let model = GitHub.model([], issues: [GitHub.issue(5)])
    var opened: [Int] = []
    model.onOpenWorktreePalette = { opened.append($0) }
    send(.rightArrow, to: model)
    send(.downArrow, to: model)
    send(.downArrow, to: model)
    send(.return, to: model)
    model.draftText = "10/6"

    send(.return, .command, to: model)

    XCTAssertEqual(model.pane.due, TaskItem.DueDate("2025-10-06"))
    XCTAssertNil(model.draft)
    XCTAssertEqual(model.store.tasks, [])
    XCTAssertEqual(opened, [])
  }

  // MARK: - 選ぶ状態の space

  /// 結び付けるタスクを選ぶ間、空の入力欄の space は何もしない（完了にせず、空白も入れない）。
  func testSpaceWhilePickingATaskDoesNothing() {
    let model = GitHub.model([TaskPaletteSamples.task(1, "a")], issues: [GitHub.issue(5)])
    send("l", .command, to: model)
    XCTAssertNotNil(model.pick, "前提: タスクを選ぶ状態")

    send(.space, to: model)

    XCTAssertEqual(model.query, "")
    XCTAssertEqual(status(model, 1), .todo)
  }
}
