import XCTest

@testable import Orbe

private typealias GitHub = TaskPaletteGitHubSamples

/// 選ぶ状態の両方向: GitHub タブの L からタスクを選ぶ（結び付ける・付け替える）、右の欄の「＋ 結び付ける」から
/// 項目を選ぶ。決めると 1 回の変異で結び付けて元の場所へ戻り、やめると何も変えずに戻る。
///
/// 壊れると何が起きるか: 選ぶ途中の space や ⌘⌫ がタスクを完了・削除する。付け替えた項目が前のタスクにも
/// 残る、別のタスクに付く。抜けた後にタスクのタブの絞り込みと選んだ行が消える。対象のタスクを agent が
/// 消した後も選ぶ状態が残り、↵ が空振りし続ける。
extension TaskPaletteModelTests {
  /// GitHub タブで Issue 5 を選んだ画面（未着手 a・b、Issue 6・5）。
  private func pickingFromIssueFive(_ tasks: [TaskItem]? = nil) -> TaskPaletteModel {
    let palette = GitHub.model(
      tasks ?? [task(1, "a"), task(2, "b")], issues: [GitHub.issue(6), GitHub.issue(5)])
    palette.tapGitHubRow(.item(GitHub.id(5)))
    return palette
  }

  // MARK: - タスクを選ぶ（GitHub タブの L）

  /// L でタスクのタブの行から選び、↵ でそのタスクの末尾に結び付けて GitHub タブのその行へ戻る。追加の行は
  /// 出さない。
  func testLinkPicksATaskAndEnterLinksItThenReturnsToTheItem() throws {
    let palette = pickingFromIssueFive([
      task(1, "a"), task(2, "b") { $0.links = [GitHub.link(3)] },
    ])

    palette.linkSelectedGitHubItem()
    XCTAssertEqual(palette.visibleTab, .tasks)
    palette.query = "b"
    XCTAssertEqual(palette.selectableIDs, [.task(2)], "打っても追加の行は出さない")
    palette.query = ""
    palette.move(1)
    palette.submit()

    XCTAssertEqual(try storedTask(palette, 2).links, [GitHub.link(3), GitHub.link(5)])
    XCTAssertNil(palette.pick)
    XCTAssertEqual(palette.visibleTab, .github)
    XCTAssertEqual(palette.selectedGitHubID, .item(GitHub.id(5)))
  }

  /// 結び付いている行の L は付け替え: 前のタスクから外し（外した項目に記録）、選んだタスクの末尾に足す。
  func testLinkOnALinkedItemMovesItToTheChosenTask() throws {
    let palette = pickingFromIssueFive([
      task(1, "a") { $0.links = [GitHub.link(5)] }, task(2, "b"),
    ])

    palette.linkSelectedGitHubItem()
    palette.move(1)
    palette.submit()

    XCTAssertEqual(try storedTask(palette, 1).links, [])
    XCTAssertEqual(try storedTask(palette, 1).unlinked, [GitHub.id(5)])
    XCTAssertEqual(try storedTask(palette, 2).links, [GitHub.link(5)])
  }

  /// 今の持ち主を選んだ ↵ は何もせず、選ぶ状態に残る。
  func testChoosingTheCurrentOwnerKeepsPicking() throws {
    let palette = pickingFromIssueFive([
      task(1, "a") { $0.links = [GitHub.link(5)] }, task(2, "b"),
    ])

    palette.linkSelectedGitHubItem()
    palette.submit()

    XCTAssertNotNil(palette.pick)
    XCTAssertEqual(try storedTask(palette, 1).links, [GitHub.link(5)])
  }

  /// esc は何も変えずに GitHub タブへ戻る。タスクのタブの入力と選択は、選ぶ状態に入る前のまま。
  func testCancellingATaskPickRestoresBothLists() throws {
    let palette = pickingFromIssueFive()
    palette.setTab(.tasks)
    palette.move(1)
    palette.setTab(.github)

    palette.linkSelectedGitHubItem()
    palette.query = "a"
    palette.cancelPick()

    XCTAssertEqual(palette.store.tasks.map(\.links), [[], []])
    XCTAssertEqual(palette.visibleTab, .github)
    XCTAssertEqual(palette.selectedGitHubID, .item(GitHub.id(5)))
    palette.setTab(.tasks)
    XCTAssertEqual(palette.query, "")
    XCTAssertEqual(palette.selectedID, .task(2))
  }

  /// タスクを選ぶ間は、選ぶこと以外でタスクを変えない（完了・削除・並べ替え・ドラッグ・右の欄・タブ切替・⌘T）。
  func testPickingATaskCannotChangeTasks() {
    let palette = pickingFromIssueFive()
    var opened: [Int] = []
    palette.onOpenWorktreePalette = { opened.append($0) }
    palette.linkSelectedGitHubItem()

    palette.toggleDone(1)
    palette.delete(2)
    palette.reorder(1)
    drop(palette, 2, by: -1)
    palette.enterDetail()
    palette.toggleTab()
    palette.openWorktreePalette()
    palette.askSecretary()
    palette.openAsk(1)

    XCTAssertEqual(palette.store.tasks.map(\.id), [1, 2])
    XCTAssertEqual(palette.store.tasks.map(\.status), [.todo, .todo])
    XCTAssertEqual(palette.area, .list)
    XCTAssertEqual(palette.visibleTab, .tasks)
    XCTAssertEqual(opened, [])
    XCTAssertNil(palette.draft, "秘書に頼む欄も開かない")
    palette.cancelPick()
    XCTAssertEqual(palette.visibleTab, .github, "やめると入る前のタブへ戻る")
  }

  /// メニューバーのピルからタスクを選ぶと、選ぶ状態をやめてそのタスクを選ぶ（次の ↵ で結び付けない）。
  func testShowingATaskEndsPicking() {
    let palette = pickingFromIssueFive()
    palette.linkSelectedGitHubItem()

    palette.showTask(2)

    XCTAssertNil(palette.pick)
    XCTAssertEqual(palette.visibleTab, .tasks)
    XCTAssertEqual(palette.selectedID, .task(2))
    XCTAssertTrue(palette.store.tasks.allSatisfy(\.links.isEmpty), "結び付けない")
  }

  /// 選んでいる項目が一覧から消えたら（閉じられた）、選ぶ状態を終えて戻る。
  func testTaskPickEndsWhenTheItemLeavesTheList() throws {
    let source = GitHub.Source()
    let palette = GitHub.model(
      [task(1, "a")], issues: [GitHub.issue(6), GitHub.issue(5)], source: source)
    palette.tapGitHubRow(.item(GitHub.id(5)))
    palette.linkSelectedGitHubItem()

    palette.openLists.open(root: TaskPaletteSamples.root)
    try XCTUnwrap(source.fetches.first { $0.kind == .issue }).finish([GitHub.issue(6)])
    palette.reconcile()

    XCTAssertNil(palette.pick)
    XCTAssertEqual(palette.visibleTab, .github)
  }

  /// 選んだタスクが消えた後に確定しても、失敗は表に出さず、選ぶ状態のまま付け直しに任せる。
  func testConfirmingATaskThatWasJustDeletedShowsNoErrorAndKeepsPicking() throws {
    let palette = pickingFromIssueFive()
    palette.linkSelectedGitHubItem()
    palette.move(1)
    try palette.store.delete(2)

    palette.confirmPick()

    XCTAssertNil(palette.error)
    XCTAssertNotNil(palette.pick)
    XCTAssertEqual(palette.selectedID, .task(1), "同じ位置の行へ付け直す")
    XCTAssertEqual(try storedTask(palette, 1).links, [], "別のタスクには結び付けない")
  }

  // MARK: - 項目を選ぶ（右の欄の「＋ 結び付ける」）

  /// 結び付きが 0 件のタスクでも「＋ 結び付ける」に止まる（結び付きの後・ステータスの前）。
  func testAddLinkStopIsThereEvenWithoutLinks() throws {
    let palette = model([task(1, "a")])

    XCTAssertEqual(
      Array(palette.detailStops(try storedTask(palette, 1)).prefix(3)),
      [.field(.title), .addLink, .field(.status)])
  }

  /// タスク 1 の右の欄の「＋ 結び付ける」に居る画面（Issue 6・5、Issue 6 はタスク 2 のもの）。
  private func atAddLink() -> TaskPaletteModel {
    let palette = GitHub.model(
      [task(1, "a"), task(2, "b") { $0.links = [GitHub.link(6)] }],
      issues: [GitHub.issue(6), GitHub.issue(5)])
    palette.setTab(.tasks)
    palette.area = .detail(.addLink)
    return palette
  }

  /// ↵ で GitHub タブの行から選び、↵ でそのタスクに結び付けて右の欄のその結び付きへ戻る。
  func testAddLinkPicksAnItemAndEnterLinksItReturningToThatLink() throws {
    let palette = atAddLink()

    palette.beginPickingItem()
    XCTAssertEqual(palette.visibleTab, .github)
    palette.tapGitHubRow(.item(GitHub.id(5)))
    palette.submit()

    XCTAssertEqual(try storedTask(palette, 1).links, [GitHub.link(5)])
    XCTAssertNil(palette.pick)
    XCTAssertEqual(palette.visibleTab, .tasks)
    XCTAssertEqual(palette.area, .detail(.link(GitHub.id(5))))
  }

  /// 別のタスクの項目を選べば付け替える。
  func testAddLinkOnAnItemOfAnotherTaskMovesIt() throws {
    let palette = atAddLink()

    palette.beginPickingItem()
    palette.tapGitHubRow(.item(GitHub.id(6)))
    palette.submit()

    XCTAssertEqual(try storedTask(palette, 1).links, [GitHub.link(6)])
    XCTAssertEqual(try storedTask(palette, 2).links, [])
  }

  /// そのタスクが既に持つ項目では何もしない。
  func testAddLinkOnAnItemTheTaskAlreadyHasDoesNothing() throws {
    let palette = atAddLink()
    palette.setTab(.tasks)
    palette.move(1)
    palette.area = .detail(.addLink)

    palette.beginPickingItem()
    palette.tapGitHubRow(.item(GitHub.id(6)))
    palette.submit()

    XCTAssertNotNil(palette.pick)
    XCTAssertEqual(try storedTask(palette, 2).links, [GitHub.link(6)])
  }

  /// esc は何も変えずに「＋ 結び付ける」へ戻る。GitHub タブの入力と選択は、入る前のまま。
  func testCancellingAnItemPickReturnsToTheAddLinkStop() throws {
    let palette = atAddLink()
    palette.setTab(.github)
    palette.tapGitHubRow(.item(GitHub.id(5)))
    palette.setTab(.tasks)
    palette.area = .detail(.addLink)

    palette.beginPickingItem()
    palette.query = "6"
    palette.cancelPick()

    XCTAssertEqual(palette.store.tasks.map(\.links), [[], [GitHub.link(6)]])
    XCTAssertEqual(palette.area, .detail(.addLink))
    palette.setTab(.github)
    XCTAssertEqual(palette.query, "")
    XCTAssertEqual(palette.selectedGitHubID, .item(GitHub.id(5)))
  }

  /// 項目を選ぶ間は、⌘T・L・→ が効かない。
  func testPickingAnItemCannotOpenLinkOrEnterThePane() {
    let palette = atAddLink()
    var opened: [Int] = []
    palette.onOpenWorktreePalette = { opened.append($0) }
    palette.beginPickingItem()
    palette.tapGitHubRow(.item(GitHub.id(5)))

    palette.openWorktreePalette()
    palette.linkSelectedGitHubItem()
    palette.enterPane()

    XCTAssertEqual(opened, [])
    XCTAssertEqual(palette.store.tasks.count, 2)
    XCTAssertEqual(palette.visibleTab, .github, "タスクを選ぶ状態へ移らない")
    XCTAssertEqual(palette.area, .list)
  }

  /// 対象のタスクを agent が消したら、選ぶ状態を終える。
  func testItemPickEndsWhenTheTaskIsDeleted() throws {
    let palette = atAddLink()
    palette.beginPickingItem()

    try palette.store.delete(1)
    palette.reconcile()

    XCTAssertNil(palette.pick)
    XCTAssertEqual(palette.area, .list)
  }
}
