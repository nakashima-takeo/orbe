import XCTest

@testable import Orbe

/// worktree ごとに 1 つの agent へまとめる規則（`WorktreeAgentActivity.index`）と、agent が完了したタスクに
/// 出ないことを固定する。
///
/// 壊れると何が起きるか: 同じ worktree に作業中と入力待ちのタブがあると、人の手を待っている方が札に出ず、
/// 入力待ちに気づかない。応答を終えたタブより休止中のタブが選ばれ、結果を見に行く ↵ が別のタブへ飛ぶ。
/// 完了したタスクの右の欄に、その worktree で始めた別の作業の agent が出て、まだ終わっていないように見える。
@MainActor
final class WorktreeAgentActivityTests: OrbeTestCase {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func agent(_ state: AgentStateIcon.Kind, minutesIn: Double, tab: Int)
    -> WorktreeAgentActivity.Agent
  {
    WorktreeAgentActivity.Agent(
      name: "claude", state: state, since: start.addingTimeInterval(minutesIn * 60), tabId: tab,
      tabTitle: "t\(tab)", branch: nil,
      defaultBranch: nil)
  }

  /// 入力待ち > 作業中 > 完了 > 休止（人の手が要るものから）。どの順で並んでいても同じ 1 つに畳む。
  func testTheWorktreeShowsWaitingThenWorkingThenDoneThenIdle() {
    let order: [AgentStateIcon.Kind] = [.waiting, .working, .done, .idle]
    for (rank, state) in order.enumerated() {
      let rivals = order[(rank + 1)...].enumerated().map { offset, lower in
        agent(lower, minutesIn: Double(10 + offset), tab: 10 + offset)
      }
      let winner = agent(state, minutesIn: 0, tab: 1)

      for tabs in [[winner] + rivals, rivals + [winner]] {
        let index = WorktreeAgentActivity.index(tabs.map { (key: "/r/wt", agent: $0) })
        XCTAssertEqual(index["/r/wt"]?.state, state, "\(state) がより低い状態より先に出る")
      }
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

  /// タスクが worktree に記録した作業のブランチで絞るのは、記録が確定していて（既定ブランチ以外）、今の
  /// ブランチが分かり、それが記録と違うときだけ。記録が無い・既定ブランチの記録は未確定で、今のブランチが
  /// 分からない（detached・reftable）ときも絞らない。
  func testTheAgentIsHiddenOnlyWhileAConfirmedRecordDiffersFromTheKnownCurrentBranch() {
    struct Case {
      let recorded: String?
      let current: String?
      let shown: Bool
    }
    let cases = [
      Case(recorded: nil, current: "x", shown: true),
      Case(recorded: "main", current: "feat", shown: true),
      Case(recorded: "feat", current: nil, shown: true),
      Case(recorded: "feat", current: "feat", shown: true),
      Case(recorded: "feat", current: "other", shown: false),
    ]
    for c in cases {
      let agent = WorktreeAgentActivity.Agent(
        name: "claude", state: .working, since: start, tabId: 1, tabTitle: "t1", branch: c.current,
        defaultBranch: "main")
      let task = TaskPaletteSamples.task(1, "a") {
        $0.worktree = TaskWorktree(key: "/r/wt")
        $0.worktreeBranch = c.recorded
      }

      XCTAssertEqual(
        task.agent(in: ["/r/wt": agent]) != nil, c.shown,
        "記録 \(c.recorded ?? "nil")・今 \(c.current ?? "nil")")
    }
  }
}
