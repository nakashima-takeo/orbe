import XCTest

@testable import Orbe

/// タスクの行が、そのタスクの worktree で作業中か入力待ちの agent を札に持つこと。同じ worktree の agent を
/// どれに畳むかの規則は `WorktreeAgentActivityTests` が持つ。
///
/// 壊れると何が起きるか: agent が worktree で作業中・入力待ちでも、タスクの行に札が出ず、どのタスクが
/// 進んでいてどれが人の手を待っているか、タスク画面から分からない。逆に応答を終えた・休止中の agent まで
/// 札に出て、一覧が札で埋まる。
extension TaskPaletteRowsTests {
  func testRowCarriesOnlyAWorkingOrWaitingAgentOfItsWorktree() {
    func agent(_ state: AgentStateIcon.Kind, tab: Int) -> WorktreeAgentActivity.Agent {
      WorktreeAgentActivity.Agent(
        name: "claude", state: state, since: Date(timeIntervalSince1970: 0), tabId: tab,
        tabTitle: "wt", branch: nil, defaultBranch: nil)
    }
    let agents = [
      "/r/wt/waiting": agent(.waiting, tab: 1), "/r/wt/working": agent(.working, tab: 2),
      "/r/wt/done": agent(.done, tab: 3), "/r/wt/idle": agent(.idle, tab: 4),
    ]
    let worktrees = ["/r/wt/waiting", "/r/wt/working", "/r/wt/done", "/r/wt/idle", "/r/wt/other"]
    let tasks = worktrees.enumerated().map { index, key in
      task(index + 1) { $0.worktree = TaskWorktree(key: key) }
    }

    let rows = TaskPaletteRows.build(input(tasks, agents: agents))
    let tabs = rows.compactMap { row -> TaskPaletteTaskRow? in
      if case .task(let row) = row { row } else { nil }
    }.map { $0.agent?.tabId }

    XCTAssertEqual(tabs, [1, 2, nil, nil, nil], "worktree が一致し、作業中か入力待ちの agent だけ")
  }
}
