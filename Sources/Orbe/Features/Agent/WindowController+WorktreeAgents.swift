import AppKit

extension WindowController {
  /// 全タブから worktree ごとの agent の索引を作り直す（`flushChrome` から）。
  func refreshWorktreeAgents() {
    let states: [String: WorktreeAgentState] = [
      "working": .working, "waiting": .waiting,
    ]
    worktreeAgents.update(
      store.allTabs().compactMap { ref in
        let tab = ref.tab
        guard let report = tab.agentReport, let state = states[report.state],
          let session = tab.agentSlot.session
        else { return nil }
        let title = tab.displayTitle(workspaceRoot: workspaces[ref.workspaceIndex].rootPath)
        return (
          tab.groupKey,
          WorktreeAgentActivity.Agent(
            name: session.command, state: state, since: report.stateChangedAt, tabId: tab.id,
            tabTitle: title)
        )
      })
  }
}
