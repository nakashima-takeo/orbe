import XCTest

@testable import Orbe

/// タスクの行が、そのタスクの worktree で動く agent を持つこと。どの agent を出すかの規則は
/// `WorktreeAgentActivityTests` が持つ。
///
/// 壊れると何が起きるか: agent が worktree で作業中・入力待ちでも、タスクの行に札が出ず、どのタスクが
/// 進んでいてどれが人の手を待っているか、タスク画面から分からない。
extension TaskPaletteRowsTests {
  func testRowCarriesTheAgentOfItsWorktreeOnly() throws {
    let agent = WorktreeAgentActivity.Agent(
      name: "claude", state: .waiting, since: Date(timeIntervalSince1970: 0), tabId: 7,
      tabTitle: "issue-221")
    let agents = ["/r/wt/issue-221": agent]
    let rows = TaskPaletteRows.build(
      input(
        [
          task(1) { $0.worktree = TaskWorktree(key: "/r/wt/issue-221") },
          task(2) { $0.worktree = TaskWorktree(key: "/r/wt/other") }, task(3),
        ], agents: agents))
    let tabs = rows.compactMap { row -> TaskPaletteTaskRow? in
      if case .task(let row) = row { row } else { nil }
    }.map { $0.agent?.tabId }

    XCTAssertEqual(tabs, [7, nil, nil], "worktree が一致する行だけ")
  }
}
