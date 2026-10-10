import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 右の欄の agent の場所で ↵ を押すと、その agent のタブへ移る。
///
/// 壊れると何が起きるか: 右の欄の「claude が取り掛かっている」に焦点を合わせて ↵ を押しても何も起きず、
/// 入力待ちの agent のタブを探しにタブ行を辿ることになる。押し続けると、同じタブへの移動が何度も走る。
extension TaskPaletteCardKeyTests {
  func testEnterOnTheAgentGoesToItsTabOnce() {
    let agent = WorktreeAgentActivity.Agent(
      name: "claude", state: .waiting, since: DesignSceneFixtures.taskToday, tabId: 42,
      tabTitle: "issue-221", branch: nil,
      defaultBranch: nil)
    let model = TaskPaletteSamples.model(
      [TaskPaletteSamples.task(1, "a") { $0.worktree = TaskWorktree(key: "/r/wt/issue-221") }],
      agents: WorktreeAgentActivity(agents: ["/r/wt/issue-221": agent]))
    var focused: [Int] = []
    model.onFocusTab = { focused.append($0) }
    let window = mount(model)
    model.enterDetail()
    model.area = .detail(.agent)
    flush(window)

    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)

    XCTAssertEqual(focused, [42])
  }
}

/// カードが agent の索引の変化を見て、右の欄の焦点を付け直す配線。
///
/// 壊れると何が起きるか: agent の場所に居る間にタブが去ると、焦点が消えた場所に残り、↑↓ も ↵ も効かなくなる。
extension TaskPaletteCardKeyTests {
  func testWhenTheAgentsTabGoesAwayTheArrowsStillMoveFromTheSamePosition() {
    let worktree = "/r/wt/issue-221"
    let agents = WorktreeAgentActivity(agents: [
      worktree: WorktreeAgentActivity.Agent(
        name: "claude", state: .working, since: DesignSceneFixtures.taskToday, tabId: 42,
        tabTitle: "issue-221", branch: nil,
        defaultBranch: nil)
    ])
    let model = TaskPaletteSamples.model(
      [TaskPaletteSamples.task(1, "a") { $0.worktree = TaskWorktree(key: worktree) }],
      agents: agents)
    let window = mount(model)
    model.enterDetail()
    model.area = .detail(.agent)
    flush(window)

    agents.update([])
    flush(window)
    XCTAssertEqual(model.area, .detail(.addLink), "同じ位置の止まる場所へ移る")

    arrow(Key.up, to: window)
    XCTAssertEqual(model.area, .detail(.field(.title)), "↑ が効く")
  }

  /// 会話の行に居る間に会話のタブが去ったら、カードが会話の索引の変化を付け直しへ届け、↑↓ が効く場所へ移る。
  func testWhenTheConversationsTabGoesAwayTheArrowsStillMove() {
    let tabs = AgentSessionTabs()
    tabs.update([.init(sessionId: "s-1", tab: .init(tabId: 7, title: "pr-214"), isDormant: false)])
    let condition = WaitCondition(
      WaitConditionRequest(
        description: "レビューが付いたら", command: "gh pr view 214", everyMinutes: 10,
        deadline: DesignSceneFixtures.taskToday.addingTimeInterval(86400),
        conversation: WaitConversation(
          command: "claude", sessionId: "s-1", workspace: nil, secretary: false)),
      setAt: DesignSceneFixtures.taskToday)
    let model = TaskPaletteSamples.model(
      [
        TaskPaletteSamples.task(1, "a") {
          $0.wait = .waiting(
            TaskItem.Waiting(
              reason: "レビュー待ち", since: DesignSceneFixtures.taskToday, condition: condition))
        }
      ], sessionTabs: tabs)
    let window = mount(model)
    model.enterDetail()
    model.area = .detail(.conversation)
    flush(window)

    tabs.update([])
    flush(window)
    XCTAssertNotEqual(model.area, .detail(.conversation), "去った会話の行に残らない")

    arrow(Key.up, to: window)
    XCTAssertEqual(model.area, .detail(.field(.title)), "↑ が効く")
  }
}
