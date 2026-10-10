import XCTest

@testable import Orbe

/// 右の欄の待ちの条件（会話の行・箱の開閉する部分の止まる場所）と、解けた待ちの ⌘T が worktree パレットを開かずに
/// 続きから始めること。
///
/// 壊れると何が起きるか: 実行の記録や確認のコマンドへ ↑↓ で辿り着けず、何が裏で走っているかを人が確かめられない。
/// 会話のタブと agent の場所が同じタブを 2 度指す。解けたタスクの ⌘T が worktree を選ばせ、記録した会話とは別の場所で
/// 新しい会話が始まる。開閉の状態が別のタスクへ持ち越される。
extension TaskPaletteModelTests {
  private func waitCondition(conversation: WaitConversation? = nil) -> WaitCondition {
    WaitCondition(
      WaitConditionRequest(
        description: "レビューが付いたら", command: "gh pr view 214", everyMinutes: 10,
        deadline: DesignSceneFixtures.taskToday.addingTimeInterval(86400),
        conversation: conversation),
      setAt: DesignSceneFixtures.taskToday)
  }

  private var conversation: WaitConversation {
    WaitConversation(command: "claude", sessionId: "s-1", workspace: nil, secretary: false)
  }

  private func waiting(_ condition: WaitCondition) -> TaskItem.Wait {
    .waiting(
      TaskItem.Waiting(reason: "レビュー待ち", since: DesignSceneFixtures.taskToday, condition: condition)
    )
  }

  private func resolved(conversation: WaitConversation?) -> TaskItem.Wait {
    .resolved(
      WaitResolution(
        waiting: TaskItem.Waiting(
          reason: "レビュー待ち", since: DesignSceneFixtures.taskToday,
          condition: waitCondition(conversation: conversation)),
        how: .satisfied(output: "レビューが付いた"), at: DesignSceneFixtures.taskToday))
  }

  func testConditionPartsStopRightAfterTheWaitingField() {
    let palette = model([task(1, "a", .inProgress) { $0.wait = self.waiting(self.waitCondition()) }]
    )
    palette.enterDetail()

    palette.moveField(1)
    palette.moveField(1)
    let parts = [palette.area]
    palette.moveField(1)

    XCTAssertEqual(
      parts + [palette.area], [.detail(.condition(.command)), .detail(.condition(.log))])
    palette.moveField(1)
    XCTAssertEqual(palette.area, .detail(.field(.priority)))
  }

  func testConditionPartsOpenAndCloseAndCloseWhenAnotherTaskIsSelected() {
    let palette = model([
      task(1, "a", .inProgress) { $0.wait = self.waiting(self.waitCondition()) },
      task(2, "b", .inProgress),
    ])

    palette.toggleConditionPart(.log)
    XCTAssertTrue(palette.isConditionPartOpen(.log))
    XCTAssertEqual(palette.area, .detail(.condition(.log)), "↵・クリックした部分へ焦点が移る")
    palette.toggleConditionPart(.log)
    XCTAssertFalse(palette.isConditionPartOpen(.log))

    palette.toggleConditionPart(.command)
    palette.leaveDetail()
    palette.move(1)
    palette.move(-1)
    XCTAssertFalse(palette.isConditionPartOpen(.command), "別のタスクを選ぶと閉じる")
  }

  /// 会話のタブがあるときだけ会話の行が止まる場所になり、同じタブを指す agent の場所は出さない。
  func testConversationStopsOnlyWhenItsTabIsOpenAndHidesTheSameTabsAgent() throws {
    let worktree = "/r/wt/pr-214"
    let agents = WorktreeAgentActivity(agents: [
      worktree: WorktreeAgentActivity.Agent(
        name: "claude", state: .working, since: DesignSceneFixtures.taskToday, tabId: 7,
        tabTitle: "pr-214", branch: nil, defaultBranch: nil)
    ])
    let tabs = AgentSessionTabs()
    let palette = TaskPaletteSamples.model(
      [
        task(1, "a", .inProgress) {
          $0.worktree = TaskWorktree(key: worktree)
          $0.wait = self.waiting(self.waitCondition(conversation: self.conversation))
        }
      ], agents: agents, sessionTabs: tabs)
    let selected = try XCTUnwrap(palette.selectedTask)

    XCTAssertEqual(
      palette.detailStops(selected).prefix(2), [.field(.title), .agent], "タブが無ければ agent だけ")

    tabs.update([.init(sessionId: "s-1", tab: .init(tabId: 7, title: "pr-214"), isDormant: false)])
    XCTAssertEqual(
      palette.detailStops(selected).prefix(3), [.field(.title), .conversation, .addLink],
      "会話のタブと同じタブの agent は出さない")

    var focused: [Int] = []
    palette.onFocusTab = { focused.append($0) }
    palette.focusConversationTab()
    XCTAssertEqual(focused, [7])
  }

  func testCommandTOnAResolvedWaitContinuesTheConversationInsteadOfOpeningTheWorktreePalette() {
    let palette = model([
      task(1, "a", .inProgress) { $0.wait = self.resolved(conversation: self.conversation) }
    ])
    var continued: [Int] = []
    var opened: [Int] = []
    palette.onContinueWait = {
      continued.append($0)
      return .failed
    }
    palette.onOpenWorktreePalette = { opened.append($0) }

    palette.openWorktreePalette()

    XCTAssertEqual(continued, [1])
    XCTAssertEqual(opened, [])
    XCTAssertEqual(palette.error, .failed, "届けられなかった理由はフッターに出す")
  }

  /// 続きから始められない（作業ディレクトリ・CLI が無い）なら、⌘T はいつもの ⌘T に戻り、理由を出し続ける。
  func testCommandTOnAResolvedWaitThatCannotContinueOpensTheWorktreePalette() {
    let palette = model([
      task(1, "a", .inProgress) { $0.wait = self.resolved(conversation: self.conversation) }
    ])
    var opened: [Int] = []
    palette.continuationBlock = { _ in .directoryMissing }
    palette.onContinueWait = { _ in
      XCTFail("始められないのに続きから始めた")
      return nil
    }
    palette.onOpenWorktreePalette = { opened.append($0) }

    palette.openWorktreePalette()
    palette.continueWait()

    XCTAssertEqual(opened, [1])
    XCTAssertEqual(palette.continuation(of: palette.store.tasks[0]), .blocked(.directoryMissing))
  }

  /// 会話の記録が無い解けた待ち（タブの外から付けた条件）の ⌘T は、いつもの ⌘T。
  func testCommandTOnAResolvedWaitWithoutAConversationOpensTheWorktreePalette() {
    let palette = model([task(1, "a", .inProgress) { $0.wait = self.resolved(conversation: nil) }])
    var opened: [Int] = []
    palette.onContinueWait = { _ in
      XCTFail("会話が無いのに続きから始めた")
      return nil
    }
    palette.onOpenWorktreePalette = { opened.append($0) }

    palette.openWorktreePalette()

    XCTAssertEqual(opened, [1])
  }
}
