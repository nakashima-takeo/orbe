import AppKit

extension WindowController {
  /// 全タブから worktree ごとの agent の索引を作り直す（`flushChrome` から）。載せるのは状態を報告している
  /// 稼働中の agent（作業中・入力待ち・完了・休止）。
  func refreshWorktreeAgents() {
    worktreeAgents.update(
      store.allTabs().compactMap { ref in
        let tab = ref.tab
        guard let report = tab.agentReport, let state = AgentStateIcon.kind(state: report.state),
          let session = tab.agentSlot.session
        else { return nil }
        let title = tab.displayTitle(workspaceRoot: workspaces[ref.workspaceIndex].rootPath)
        return (
          tab.groupKey,
          WorktreeAgentActivity.Agent(
            name: session.command, state: state, since: report.stateChangedAt, tabId: tab.id,
            tabTitle: title, branch: GitWorktreeRoot.branch(at: tab.groupKey),
            defaultBranch: GitWorktreeRoot.defaultBranch(at: tab.groupKey))
        )
      })
  }
}
