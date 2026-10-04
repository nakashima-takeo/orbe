import AppKit
import XCTest

@testable import Orbe

private typealias GitHub = TaskPaletteGitHubSamples

/// GitHub タブ・右の欄・選ぶ状態のキーと、一覧の置き場の変化をカードが付け直しへ届ける配線。
///
/// 壊れると何が起きるか: 絞り込みに「l」を打つと結び付けが始まる、入力を消す ⌫ が結び付きを外す、押し続けた
/// ⌫ が選択の移った先の結び付きまで外す。⇥ が絞り込みでなく範囲を切り替える。選ぶ状態の esc で画面ごと
/// 閉じる。項目を選ぶ間の ⌫ で、別のタスクの結び付きが外れる。一覧が取り直されて行が消えても、消えた行を
/// 選んだまま ↵ が空振りする。
extension TaskPaletteCardKeyTests {
  private enum GitHubKey {
    static let l: UInt16 = 37
  }

  /// L は入力欄が空のときだけ結び付けを始める。文字があれば「l」を打つ。
  func testLStartsLinkingOnlyWhileTheFieldIsEmpty() {
    let model = GitHub.model([TaskPaletteSamples.task(1, "a")], issues: [GitHub.issue(5)])
    let window = mount(model)

    type("x", into: window)
    press(GitHubKey.l, "l", to: window)
    XCTAssertEqual(model.query, "xl")
    XCTAssertNil(model.pick)

    model.query = ""
    flush(window)
    press(GitHubKey.l, "L", .shift, to: window)
    XCTAssertNotNil(model.pick, "⇧ が付いていても結び付けを始める")
    XCTAssertEqual(model.visibleTab, .tasks)
  }

  /// ⌫ は入力欄が空のときだけ結び付きを外す。文字があれば 1 文字消す。
  func testBackspaceUnlinksOnlyWhileTheFieldIsEmpty() throws {
    let model = GitHub.model(
      [TaskPaletteSamples.task(1, "a") { $0.links = [GitHub.link(6), GitHub.link(5)] }],
      issues: [GitHub.issue(6), GitHub.issue(5)])
    let window = mount(model)

    type("6", into: window)
    press(Key.delete, "\u{7F}", to: window)
    XCTAssertEqual(model.query, "")
    XCTAssertEqual(model.store.tasks.first?.links.count, 2, "文字を消すだけ")

    press(Key.delete, "\u{7F}", to: window)

    XCTAssertEqual(model.store.tasks.first?.links, [GitHub.link(5)])
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

    press(GitHubKey.l, "l", to: window)
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

  /// 項目を選ぶ間の ⌫ は、選んだ行の結び付き（別のタスクのもの）を外さない。
  func testBackspaceWhilePickingAnItemDoesNotUnlink() {
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

    press(Key.delete, "\u{7F}", to: window)

    XCTAssertEqual(model.store.tasks.last?.links, [GitHub.link(5)])
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
}
