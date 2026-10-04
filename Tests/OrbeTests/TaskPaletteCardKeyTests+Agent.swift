import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 詳細の agent の場所で ↵ を押すと、その agent のタブへ移る。
///
/// 壊れると何が起きるか: 詳細の「claude が取り掛かっている」に焦点を合わせて ↵ を押しても何も起きず、
/// 入力待ちの agent のタブを探しにタブ行を辿ることになる。押し続けると、同じタブへの移動が何度も走る。
extension TaskPaletteCardKeyTests {
  func testEnterOnTheAgentGoesToItsTabOnce() {
    let agent = WorktreeAgentActivity.Agent(
      name: "claude", state: .waiting, since: DesignSceneFixtures.taskToday, tabId: 42,
      tabTitle: "issue-221")
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

/// カードが agent の索引の変化を見て、詳細の焦点を付け直す配線。
///
/// 壊れると何が起きるか: agent の場所に居る間にタブが去ると、焦点が消えた場所に残り、↑↓ も ↵ も効かなくなる。
extension TaskPaletteCardKeyTests {
  func testWhenTheAgentsTabGoesAwayTheArrowsStillMoveFromTheSamePosition() {
    let worktree = "/r/wt/issue-221"
    let agents = WorktreeAgentActivity(agents: [
      worktree: WorktreeAgentActivity.Agent(
        name: "claude", state: .working, since: DesignSceneFixtures.taskToday, tabId: 42,
        tabTitle: "issue-221")
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
}
