import XCTest

@testable import Orbe

/// worktree ごとに 1 つの agent へまとめる規則（`WorktreeAgentActivity.index`）と、agent の札が完了したタスクに
/// 出ないことを固定する。
///
/// 壊れると何が起きるか: 同じ worktree に作業中と入力待ちのタブがあると、人の手を待っている方が札に出ず、
/// 入力待ちに気づかない。完了したタスクの行に、その worktree で始めた別の作業の札が出て、まだ終わって
/// いないように見える。
@MainActor
final class WorktreeAgentActivityTests: OrbeTestCase {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func agent(_ state: WorktreeAgentState, minutesIn: Double, tab: Int)
    -> WorktreeAgentActivity.Agent
  {
    WorktreeAgentActivity.Agent(
      name: "claude", state: state, since: start.addingTimeInterval(minutesIn * 60), tabId: tab,
      tabTitle: "t\(tab)")
  }

  func testWaitingWinsOverWorkingInTheSameWorktreeWhicheverComesFirst() {
    let working = agent(.working, minutesIn: 10, tab: 1)
    let waiting = agent(.waiting, minutesIn: 0, tab: 2)

    for tabs in [[working, waiting], [waiting, working]] {
      let index = WorktreeAgentActivity.index(tabs.map { (key: "/r/wt", agent: $0) })
      XCTAssertEqual(index["/r/wt"]?.tabId, 2, "入力待ちが出る")
    }
  }

  func testTheMostRecentOfTheSameStateWins() {
    let older = agent(.working, minutesIn: 0, tab: 1)
    let newer = agent(.working, minutesIn: 5, tab: 2)

    for tabs in [[older, newer], [newer, older]] {
      let index = WorktreeAgentActivity.index(tabs.map { (key: "/r/wt", agent: $0) })
      XCTAssertEqual(index["/r/wt"]?.tabId, 2, "その状態になったのが新しい方")
    }
  }

  func testADoneTaskShowsNoAgentEvenWhenItsWorktreeHasOne() {
    let agents = ["/r/wt": agent(.working, minutesIn: 0, tab: 1)]
    var task = TaskPaletteSamples.task(1, "a") { $0.worktree = TaskWorktree(key: "/r/wt") }
    XCTAssertEqual(task.agent(in: agents)?.tabId, 1)

    task.status = .done

    XCTAssertNil(task.agent(in: agents))
  }
}
