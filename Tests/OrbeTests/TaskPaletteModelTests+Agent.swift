import XCTest

@testable import Orbe

/// 詳細の agent の場所（タイトルと Issue・PR の欄の間で ↑↓ が止まる場所）の並びと、agent の状態が変わった・
/// タブが去ったときの焦点の付け直し、↵ でそのタブへ移ること。
///
/// 壊れると何が起きるか: 応答を終えた・休止中の agent のタブへ、結果を見に・続きを頼みにタスク画面から
/// 移れない。agent の場所で待っている間に応答が終わると焦点が隣の Issue へ滑り、↵ がタブ移動のつもりで
/// ブラウザを開く。タブが去った後も焦点が消えた場所に残り、↑↓ も ↵ も効かなくなる。
extension TaskPaletteModelTests {
  private static let worktree = "/r/wt/issue-221"

  private func agent(_ state: AgentStateIcon.Kind, tab: Int = 42) -> WorktreeAgentActivity.Agent {
    WorktreeAgentActivity.Agent(
      name: "claude", state: state, since: DesignSceneFixtures.taskToday, tabId: tab,
      tabTitle: "issue-221", branch: nil)
  }

  /// worktree を持ち Issue 1 と PR 2 が結び付いたタスクを選び、その worktree に `state` の agent がいる詳細。
  private func detailWithAgent(_ state: AgentStateIcon.Kind) -> TaskPaletteModel {
    let palette = TaskPaletteSamples.model(
      [
        task(1, "a") {
          $0.worktree = TaskWorktree(key: Self.worktree)
          $0.links = [self.link(.issue, 1), self.link(.pr, 2)]
        }
      ], agents: WorktreeAgentActivity(agents: [Self.worktree: agent(state)]))
    palette.enterDetail()
    return palette
  }

  private func setAgent(_ palette: TaskPaletteModel, _ agent: WorktreeAgentActivity.Agent?) {
    palette.agents.update(agent.map { [(key: Self.worktree, agent: $0)] } ?? [])
    palette.reconcile()
  }

  func testTheAgentStopsBetweenTheTitleAndTheLinks() {
    let palette = detailWithAgent(.working)
    var visited: [TaskPaletteArea] = []

    for _ in 0..<5 {
      palette.moveField(-1)
      visited.append(palette.area)
    }

    XCTAssertEqual(
      visited,
      [
        .detail(.addLink), .detail(.link(link(.pr, 2).item)), .detail(.link(link(.issue, 1).item)),
        .detail(.agent),
        .detail(.field(.title)),
      ], "ステータスから上へ: 結び付ける → 結び付き（逆順）→ agent → タイトル")
  }

  /// 応答を終えた・休止中の agent でも詳細に場所があり、↵ でそのタブへ移る。
  func testADoneOrIdleAgentStillHasItsStopAndEnterGoesToItsTab() {
    for state in [AgentStateIcon.Kind.done, .idle] {
      let palette = detailWithAgent(state)
      var focused: [Int] = []
      palette.onFocusTab = { focused.append($0) }
      palette.area = .detail(.agent)
      palette.reconcile()
      XCTAssertEqual(palette.area, .detail(.agent), "\(state): 場所がある")

      palette.focusAgentTab()

      XCTAssertEqual(focused, [42], "\(state): そのタブへ移る")
    }
  }

  func testFocusStaysOnTheAgentWhenItFinishesItsTurn() {
    let palette = detailWithAgent(.working)
    palette.area = .detail(.agent)

    setAgent(palette, agent(.done))

    XCTAssertEqual(palette.area, .detail(.agent), "応答を終えても焦点は滑らない")
  }

  func testFocusMovesToTheSamePositionWhenTheAgentsTabGoesAway() {
    let palette = detailWithAgent(.working)
    palette.area = .detail(.agent)

    setAgent(palette, nil)

    XCTAssertEqual(palette.area, .detail(.link(link(.issue, 1).item)), "同じ位置の止まる場所へ移る")
  }
}
