import AppKit
import XCTest

@testable import Orbe

private typealias GitHub = TaskPaletteGitHubSamples

/// GitHub タブ・右の欄・選ぶ状態の、入力欄に届くキーと、一覧の置き場の変化をカードが付け直しへ届ける配線。
///
/// 壊れると何が起きるか: 絞り込みに「l」を打つと結び付けが始まる。押し続けた ↵ が、押した行より先の行までタスクにする
/// （未確認の項目に自分をアサインする）。右の欄の期限で打った日付が絞り込みに入る、期限の ↵ でタスクができる、期限を
/// 打っている間の ⇥ で打った文字が消える。選ぶ状態の → で文字のカーソルが動かない。一覧が取り直されて行が消えても、
/// 消えた行を選んだまま ↵ が空振りする。
extension TaskPaletteCardKeyTests {
  private enum GitHubKey {
    static let l: UInt16 = 37
  }

  /// ⌘L は入力欄に文字があっても結び付けを始め、入力は変えない。素の l・L は文字として入る。
  func testCommandLStartsLinkingAndPlainLTypes() {
    let model = GitHub.model([TaskPaletteSamples.task(1, "a")], issues: [GitHub.issue(5)])
    let window = mount(model)

    send(GitHubKey.l, "l", to: window)
    send(GitHubKey.l, "L", .shift, to: window)
    XCTAssertEqual(model.query, "lL")
    XCTAssertNil(model.pick)

    model.query = ""
    flush(window)
    type("5", into: window)
    XCTAssertEqual(model.query, "5", "前提")
    send(GitHubKey.l, "l", .command, to: window)
    XCTAssertNotNil(model.pick)
    XCTAssertEqual(model.visibleTab, .tasks)
    model.cancelPick()
    XCTAssertEqual(model.query, "5", "GitHub タブの入力は変えない")
  }

  /// 右の欄の項目でも ⇥ で次のタブへ移る。期限を打っている間は何もせず、打った文字が残る。
  func testTabInThePaneMovesToTheNextTabButNotWhileTypingTheDue() {
    let model = GitHub.model([], issues: [GitHub.issue(5)])
    let window = mount(model)
    arrow(Key.right, to: window)
    arrow(Key.down, to: window)
    arrow(Key.down, to: window)
    send(Key.enter, "\r", to: window)
    type("10/6", into: window)

    send(Key.tab, "\t", to: window)
    XCTAssertEqual(model.tab, .github)
    XCTAssertEqual(model.draft?.text, "10/6")

    send(Key.escape, "\u{1B}", to: window)
    XCTAssertNil(model.draft, "esc は打った期限を取り消す")
    XCTAssertEqual(model.area, .pane(.due), "前提: 期限の項目に居る")
    send(Key.tab, "\t", to: window)
    XCTAssertEqual(model.tab, .automation)
  }

  /// 一覧が取り直されて選んだ行が消えたら、カードが付け直し、同じ位置の行を選ぶ。
  func testListRefetchRemovingTheSelectedRowMovesTheSelection() throws {
    let source = GitHub.Source()
    let model = GitHub.model(
      [], issues: [GitHub.issue(7), GitHub.issue(6), GitHub.issue(5)], source: source)
    let window = mount(model)
    model.move(1)

    model.openLists.open(root: TaskPaletteSamples.root)
    try XCTUnwrap(source.fetches.first { $0.kind == .issue })
      .finish([GitHub.issue(7), GitHub.issue(5)])
    flush(window)

    XCTAssertEqual(model.selectedGitHubID, .item(GitHub.id(5)))
  }

  // MARK: - タスクにして開く（⌘↵）

  // MARK: - ブラウザで開く（⌘O）

  /// 右の欄の期限で ↵ を押し続けても、押した ↵ で打ち始め、続くリピートで確定しない（編集のまま）。
  func testEnterHeldOnThePaneDueStartsTypingOnceAndKeepsTyping() {
    let model = GitHub.model([], issues: [GitHub.issue(5)])
    let window = mount(model)
    arrow(Key.right, to: window)
    arrow(Key.down, to: window)
    arrow(Key.down, to: window)
    XCTAssertEqual(
      model.area, .pane(.due),
      "前提: → で右の欄へ入り、期限に居る。testRightArrowWhilePickingATaskMovesTheCaretInTheField の"
        + "「選ぶ状態の → は右の欄へ入らない」の対で、これが待たずに成り立たなくなったら、そのテストが確かめる時点も成り立たない")

    send(Key.enter, "\r", to: window)
    send(Key.enter, "\r", repeating: true, to: window)
    send(Key.enter, "\r", repeating: true, to: window)

    XCTAssertEqual(model.draft?.target, .paneDue, "リピートで確定しない")
    XCTAssertTrue(model.store.tasks.isEmpty)
  }

  // MARK: - 選ぶ状態の入力欄の →

  /// タスクを選ぶ間、タスクの行を選んでいても入力欄の → は文字のカーソルを進める（右の欄へ入らない）。
  func testRightArrowWhilePickingATaskMovesTheCaretInTheField() throws {
    let model = GitHub.model([TaskPaletteSamples.task(1, "abc")], issues: [GitHub.issue(5)])
    let window = mount(model)
    send(GitHubKey.l, "l", .command, to: window)
    type("ab", into: window)
    XCTAssertEqual(model.selectedID, .task(1), "前提: タスクの行を選んでいる")
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "前提: 入力欄の field editor")
    arrow(Key.left, to: window)
    XCTAssertEqual(editor.selectedRange().location, 1, "前提: ← でカーソルが戻る")

    arrow(Key.right, to: window)

    XCTAssertEqual(editor.selectedRange().location, 2)
    XCTAssertEqual(model.area, .list)
  }

  // MARK: - 押し続けた ↵

  /// 「さらに」で ↵ を押し続けても、区分が開くだけでタスクは増えない（出てきた項目に自分を足さない）。
  func testEnterHeldOnMoreOnlyExpandsTheSection() {
    let source = GitHub.Source()
    let model = GitHub.model([], issues: (1...7).map { GitHub.issue($0) }, source: source)
    let window = mount(model)
    model.jump(1)
    XCTAssertEqual(model.selectedGitHubID, .more(.issue), "前提: さらに")

    send(Key.enter, "\r", to: window)
    send(Key.enter, "\r", repeating: true, to: window)
    send(Key.enter, "\r", repeating: true, to: window)

    XCTAssertEqual(model.expandedKinds, [.issue])
    XCTAssertTrue(model.store.tasks.isEmpty)
    XCTAssertTrue(source.writes.isEmpty)
  }

  // MARK: - 選ぶ状態の space

  // MARK: - 右の欄の期限

  /// 期限の ↵ で打ち始め、打った文字は絞り込みに入らず、↵ で欄の値になる。優先度へ移った ↵ はタスクにする。
  func testPaneDueIsTypedWithEnterAndEnterElsewhereMakesTheTask() throws {
    let model = GitHub.model([], issues: [GitHub.issue(5)])
    let window = mount(model)
    arrow(Key.right, to: window)
    arrow(Key.down, to: window)
    arrow(Key.down, to: window)
    XCTAssertEqual(model.area, .pane(.due), "前提: 期限")

    send(Key.enter, "\r", to: window)
    XCTAssertTrue(model.store.tasks.isEmpty, "期限の ↵ はタスクにしない")
    type("10/6", into: window)
    XCTAssertEqual(model.query, "", "打った文字は絞り込みに入らない")
    send(Key.enter, "\r", to: window)
    XCTAssertEqual(model.pane.due, TaskItem.DueDate("2025-10-06"))
    XCTAssertNil(
      model.draft,
      "期限の ↵ で確定する。testEnterHeldOnThePaneDueStartsTypingOnceAndKeepsTyping の「リピートで確定しない」"
        + "の対で、これが待たずに成り立たなくなったら、そのテストが確かめる時点も成り立たない")

    arrow(Key.up, to: window)
    send(Key.enter, "\r", to: window)

    let made = try XCTUnwrap(
      model.store.tasks.first,
      "優先度の ↵ でタスクにする。testEnterHeldOnMoreOnlyExpandsTheSection の「リピートでタスクを作らない」"
        + "の対で、これが待たずに成り立たなくなったら、そのテストが確かめる時点も成り立たない")
    XCTAssertEqual(made.due, TaskItem.DueDate("2025-10-06"))
    XCTAssertEqual(made.links, [GitHub.link(5)])
  }
}
