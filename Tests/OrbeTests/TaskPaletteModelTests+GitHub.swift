import XCTest

@testable import Orbe

private typealias GitHub = TaskPaletteGitHubSamples

/// GitHub タブ（開いた workspace のリポジトリの open な Issue・PR）の操作: 本体の出し方、タスクにする（右の欄の
/// 値と、自分を GitHub に足す書き込み）、⌘T、結び付いたタスクへ移る・外す、絞り込み、「さらに」、右の欄、
/// タブごとの入力と選択、agent の変更への追従。
///
/// 壊れると何が起きるか: ↵ で作ったタスクが別の workspace・別の項目に付く、右の欄で選んだ優先度や期限が
/// 落ちる。選択が動いた後に裏の書き込みが別の項目へアサインする。アサインが黙って捨てられても何も言わない。
/// 前回の一覧があるのに「取得できませんでした」で隠れる。タブを移るたびに絞り込みと選んだ行が消える。agent が
/// 結び付けた直後に、右の欄の値が別の行のものとして残る。
extension TaskPaletteModelTests {
  // MARK: - 本体

  /// 前回の一覧があれば、解決が使えない・取り直しが失敗していても一覧を描く。
  func testBodyDrawsThePreviousListsEvenWhenUnavailableOrFailing() {
    var repository = GitHubOpenLists.Repository()
    repository.issues = .init(items: [GitHub.issue(5)], growing: false, failed: true)
    let lists = GitHub.lists(
      [
        TaskPaletteSamples.root: .init(resolution: .unavailable(.ghUnauthed), repo: GitHub.repo)
      ],
      [GitHub.repo: repository])
    let palette = TaskPaletteSamples.model([], openLists: lists)

    XCTAssertEqual(palette.gitHubBody, .lists)
    XCTAssertEqual(palette.gitHubCount, 1, "ヘッダーの「GitHub N」は取れた件数")
  }

  /// 一覧が無ければ、使えない理由 → 取得の失敗（どちらも取得中でない）→ 読み込み中、の順に 1 行で言う。
  func testBodyWithoutListsSaysWhy() {
    func body(_ root: GitHubOpenLists.Root?, _ repository: GitHubOpenLists.Repository?)
      -> TaskPaletteGitHubBody
    {
      let lists = GitHub.lists(
        root.map { [TaskPaletteSamples.root: $0] } ?? [:],
        repository.map { [GitHub.repo: $0] } ?? [:])
      return TaskPaletteSamples.model([], openLists: lists).gitHubBody
    }
    var failed = GitHubOpenLists.Repository()
    failed.issues.failed = true
    var stillGrowing = failed
    stillGrowing.pullRequests.growing = true

    XCTAssertEqual(
      body(.init(resolution: .unavailable(.ghMissing), repo: nil), nil), .unavailable(.ghMissing))
    XCTAssertEqual(body(.init(resolution: .resolved, repo: GitHub.repo), failed), .failed)
    XCTAssertEqual(
      body(.init(resolution: .resolved, repo: GitHub.repo), stillGrowing), .loading)
    XCTAssertEqual(body(.init(resolution: .resolving, repo: nil), nil), .loading)
    XCTAssertNil(TaskPaletteSamples.model([]).gitHubCount, "まだ何も取れていなければ件数を出さない")
  }

  // MARK: - タスクにする

  /// ↵ で、開いた workspace の未着手のタスクを、右の欄の優先度と期限、その項目を主の結び付きとして足す。
  /// 行は結び付いた行として区分の上へ移り、選択はその行を追い、右の欄は既定に戻る。
  func testEnterOnAnUnlinkedItemMakesATodoTaskWithThePaneValues() throws {
    let palette = GitHub.model([], issues: [GitHub.issue(7), GitHub.issue(5, "ログの保存先")])
    palette.tapGitHubRow(.item(GitHub.id(5)))
    palette.enterPane()
    palette.movePaneStop(1)
    palette.changePaneValue(-1)
    palette.beginPaneDue()
    palette.draftText = "10/6"
    XCTAssertTrue(palette.endEditing(commit: true))

    palette.submit()

    let made = try XCTUnwrap(palette.store.tasks.last)
    XCTAssertEqual(made.title, "ログの保存先")
    XCTAssertEqual(made.status, .todo)
    XCTAssertEqual(made.workspace, openedWorkspace.id)
    XCTAssertEqual(made.priority, .high)
    XCTAssertEqual(made.due, TaskItem.DueDate("2025-10-06"))
    XCTAssertEqual(made.links, [GitHub.link(5)])
    XCTAssertEqual(
      palette.gitHubSelectableIDs, [.item(GitHub.id(5)), .item(GitHub.id(7))], "結び付いた行は上へ")
    XCTAssertEqual(palette.selectedGitHubID, .item(GitHub.id(5)))
    XCTAssertEqual(palette.selectedGitHubRow?.task?.id, made.id)
    XCTAssertEqual(palette.pane, TaskGitHubPane(owner: .item(GitHub.id(5))))
    XCTAssertEqual(palette.area, .list)
  }

  /// チェックがオンなら、押した項目に自分を足す——Issue は担当者、チーム宛のレビュー依頼だけの PR は
  /// レビュアー。書き込む項目は押した瞬間の項目で、その後に選択が動いても変わらない。
  func testMakingATaskAddsSelfToThePressedItemWithItsRole() {
    let source = GitHub.Source()
    let palette = GitHub.model(
      [], issues: [GitHub.issue(5)], pullRequests: [GitHub.pullRequest(9, teams: ["o/core"])],
      reviewRequests: [9], source: source)

    palette.submit()
    palette.move(1)
    palette.submit()

    XCTAssertEqual(source.writes.map(\.item), [GitHub.id(5), GitHub.id(9)])
    XCTAssertEqual(source.writes.map(\.role), [.assignee, .reviewer])
  }

  func testUncheckedAssignMakesTheTaskWithoutWritingToGitHub() {
    let source = GitHub.Source()
    let palette = GitHub.model([], issues: [GitHub.issue(5)], source: source)

    palette.enterPane()
    palette.togglePaneAssign()
    palette.submit()

    XCTAssertEqual(palette.store.tasks.count, 1)
    XCTAssertTrue(source.writes.isEmpty)
  }

  /// GitHub が自分を入れなかった（push 権限が無いと黙って捨てる）なら、フッターに出し、項目に記録する。
  /// 作ったタスクは消さない。
  func testFailedAssignIsReportedAndTheTaskStays() throws {
    let source = GitHub.Source()
    let palette = GitHub.model([], issues: [GitHub.issue(5)], source: source)

    palette.submit()
    try XCTUnwrap(source.writes.first).completion(["alice"])

    XCTAssertEqual(palette.error, .assign)
    XCTAssertEqual(palette.writeFailure(GitHub.id(5)), .assignee)
    XCTAssertEqual(palette.store.tasks.map(\.links), [[GitHub.link(5)]])
  }

  /// 右の欄の期限が読めない文字のままなら、タスクにせずに理由を出し、打ちかけを残す。
  func testUnreadablePaneDueStopsMakingTheTask() throws {
    let palette = GitHub.model([], issues: [GitHub.issue(5)])
    palette.enterPane()
    palette.beginPaneDue()
    palette.draftText = "あした"

    XCTAssertNil(palette.makeTask(try XCTUnwrap(palette.selectedGitHubRow)))

    XCTAssertTrue(palette.store.tasks.isEmpty)
    XCTAssertEqual(palette.error, .due)
    XCTAssertEqual(palette.draftText, "あした")
  }

  /// 押す前に agent がその項目を別のタスクに結び付けていたら、ストアが拒否し、タスクは足さない。
  func testMakingATaskForAnItemTheAgentJustLinkedIsRefused() throws {
    let source = GitHub.Source()
    let palette = GitHub.model([], issues: [GitHub.issue(5)], source: source)
    let row = try XCTUnwrap(palette.selectedGitHubRow)
    _ = try palette.store.add(TaskDraft(title: "agent", links: [GitHub.link(5)]))

    XCTAssertNil(palette.makeTask(row))

    XCTAssertEqual(palette.error, .link)
    XCTAssertEqual(palette.store.tasks.map(\.title), ["agent"])
    XCTAssertTrue(source.writes.isEmpty, "GitHub にも書かない")
  }

  // MARK: - ⌘T

  /// 結び付いていない行の ⌘T はタスクにしてからそのタスクで開く。アサインの失敗は、画面を閉じた後でも
  /// 次に開いた画面でその項目に見える。
  func testCommandTOnAnUnlinkedItemMakesTheTaskThenOpensIt() throws {
    let source = GitHub.Source()
    let palette = GitHub.model([], issues: [GitHub.issue(5)], source: source)
    var opened: [Int] = []
    palette.onOpenWorktreePalette = { opened.append($0) }

    palette.openWorktreePalette()
    try XCTUnwrap(source.writes.first).completion(nil)

    XCTAssertEqual(opened, palette.store.tasks.map(\.id))
    XCTAssertEqual(palette.store.tasks.first?.links, [GitHub.link(5)])
    let reopened = TaskPaletteSamples.model(palette.store.tasks, openLists: palette.openLists)
    XCTAssertEqual(reopened.writeFailure(GitHub.id(5)), .assignee)
  }

  func testCommandTOnALinkedItemOpensItsTask() {
    let palette = GitHub.model(
      [task(4, "a") { $0.links = [GitHub.link(5)] }], issues: [GitHub.issue(5)])
    var opened: [Int] = []
    palette.onOpenWorktreePalette = { opened.append($0) }

    palette.openWorktreePalette()

    XCTAssertEqual(opened, [4])
    XCTAssertEqual(palette.store.tasks.count, 1, "タスクを足さない")
  }

  // MARK: - 結び付いている行

  /// ↵ でタスクのタブのそのタスクへ移る。範囲・入力・完了の欄で隠れていれば見えるように切り替える。
  func testEnterOnALinkedItemRevealsItsTaskOnTheTasksTab() throws {
    let palette = GitHub.model(
      [
        task(1, "a"),
        task(2, "b", .done) {
          $0.workspace = self.otherWorkspace.id
          $0.links = [GitHub.link(5)]
        },
      ], issues: [GitHub.issue(5)])
    palette.toggleTab()
    palette.setScope(.opened)
    palette.query = "zzz"
    palette.toggleTab()

    palette.submit()

    XCTAssertEqual(palette.visibleTab, .tasks)
    XCTAssertEqual(palette.scope, .all)
    XCTAssertTrue(palette.doneExpanded)
    XCTAssertEqual(palette.query, "")
    XCTAssertEqual(palette.selectedID, .task(2))
  }

  /// ⌫ で結び付きを外す（外した項目に記録する）。行は結び付いていない側へ戻り、選択はその行に残る。
  func testUnlinkingReturnsTheRowToTheUnlinkedSide() throws {
    let palette = GitHub.model(
      [task(1, "a") { $0.links = [GitHub.link(5), GitHub.link(6)] }],
      issues: [GitHub.issue(7), GitHub.issue(6), GitHub.issue(5)])
    palette.tapGitHubRow(.item(GitHub.id(5)))

    palette.unlinkSelectedGitHubItem()

    let task = try storedTask(palette, 1)
    XCTAssertEqual(task.links, [GitHub.link(6)])
    XCTAssertEqual(task.unlinked, [GitHub.id(5)])
    XCTAssertEqual(
      palette.gitHubSelectableIDs, [.item(GitHub.id(6)), .item(GitHub.id(7)), .item(GitHub.id(5))])
    XCTAssertEqual(palette.selectedGitHubID, .item(GitHub.id(5)))
  }

  // MARK: - 絞り込み・さらに

  /// ⇥ は札を「すべて → 担当が自分 → 作成者が自分 → レビュー依頼」と巡回し、一覧の先頭を選ぶ。
  func testTabCyclesTheFiltersAndSelectsTheFirstRow() {
    let palette = GitHub.model(
      [],
      issues: [GitHub.issue(7), GitHub.issue(6, author: "me"), GitHub.issue(5, assignees: ["me"])],
      pullRequests: [GitHub.pullRequest(9)], reviewRequests: [9])
    var seen: [(TaskGitHubFilter, TaskPaletteGitHubRowID?)] = []

    for _ in 0..<4 {
      palette.cycleGitHubFilter()
      seen.append((palette.githubFilter, palette.selectedGitHubID))
    }

    XCTAssertEqual(seen.map(\.0), [.assigned, .authored, .reviewRequested, .all])
    XCTAssertEqual(
      seen.map(\.1),
      [.item(GitHub.id(5)), .item(GitHub.id(6)), .item(GitHub.id(9)), .item(GitHub.id(7))])
  }

  /// 「さらに」の ↵ で区分の残りを出し、選択は同じ位置の行（出てきた最初の行）へ移る。
  func testMoreShowsTheRestAndSelectsTheFirstNewlyShownRow() {
    let palette = GitHub.model([], issues: (1...7).map { GitHub.issue($0) })
    palette.jump(1)
    XCTAssertEqual(palette.selectedGitHubID, .more(.issue))

    palette.submit()

    XCTAssertEqual(palette.gitHubSelectableIDs, (1...7).reversed().map { .item(GitHub.id($0)) })
    XCTAssertEqual(palette.selectedGitHubID, .item(GitHub.id(2)))
  }

  // MARK: - タブごとの入力と選択

  /// タスクのタブと GitHub タブは、それぞれ自分の入力と選択を持つ。
  func testEachTabKeepsItsOwnQueryAndSelection() {
    let palette = GitHub.model(
      [task(1, "a"), task(2, "b")], issues: [GitHub.issue(6), GitHub.issue(5)])
    palette.query = "5"
    palette.toggleTab()
    palette.move(1)

    palette.toggleTab()
    XCTAssertEqual(palette.query, "5")
    XCTAssertEqual(palette.selectedGitHubID, .item(GitHub.id(5)))

    palette.toggleTab()
    XCTAssertEqual(palette.query, "")
    XCTAssertEqual(palette.selectedID, .task(2))
  }
}
