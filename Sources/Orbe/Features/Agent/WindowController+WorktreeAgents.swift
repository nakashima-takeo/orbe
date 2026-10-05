import AppKit

extension WindowController {
  /// 全タブから worktree ごとの agent の索引を作り直す（`flushChrome` から）。載せるのは状態を報告している
  /// 稼働中の agent（作業中・入力待ち・完了・休止）。
  func refreshWorktreeAgents() {
    var branches: [String: String?] = [:]
    worktreeAgents.update(
      store.allTabs().compactMap { ref in
        let tab = ref.tab
        guard let report = tab.agentReport, let state = AgentStateIcon.kind(state: report.state),
          let session = tab.agentSlot.session
        else { return nil }
        let title = tab.displayTitle(workspaceRoot: workspaces[ref.workspaceIndex].rootPath)
        let key = tab.groupKey
        let branch = branches[key] ?? GitWorktreeRoot.branch(at: key)
        branches[key] = branch
        return (
          key,
          WorktreeAgentActivity.Agent(
            name: session.command, state: state, since: report.stateChangedAt, tabId: tab.id,
            tabTitle: title, branch: branch)
        )
      })
  }
}
