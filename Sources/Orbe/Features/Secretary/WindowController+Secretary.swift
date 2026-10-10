import Foundation

/// 秘書の係（`Secretary`）を窓に配線する。秘書のタブは Home に選ばずに起こし、会話ごとのタブの索引で見つける。
extension WindowController: SecretaryHost {
  func secretaryTab(_ id: Int) -> TerminalTab? {
    controlResolveTab(id)
  }

  /// 索引は chrome の合流点が作り直すので、合流点の外（頼まれた・起動時）では古いことがある。引く前に作り直す。
  func secretaryTab(session: String) -> TerminalTab? {
    refreshAgentSessionTabs()
    return agentSessionTabs.tabs[session].flatMap { controlResolveTab($0.tabId) }
  }

  var secretaryClaude: AgentCLI? {
    agentLauncher.detectedAgents.first { $0.command == "claude" }
  }

  func secretaryOpen(command: String) -> TerminalTab? {
    guard let index = store.homeIndex, let home = HomeFolder.url?.path,
      let opened = openTab(
        workspaceIndex: index, cwd: home, command: command, env: agentLauncher.launchEnvironment,
        agent: "claude", selects: false)
    else { return nil }
    return controlResolveTab(opened.tabId)
  }

  func secretaryWake(_ tab: TerminalTab) {
    wakeUnselected(tab)
  }

  /// 起動時に 1 度、agent の検出が済んだら、溜めた頼みのために秘書を起こす（溜めが無ければ起こさない）。
  /// 検出は画面を開くたびにやり直されるので、2 度目以降の知らせでは起こさない——人が秘書のタブを閉じても、
  /// 勝手に起こし直さない。
  func resumeSecretaryAtLaunch() {
    agentLauncher.onResolved = { [weak self] in
      guard let self else { return }
      self.agentLauncher.onResolved = nil
      self.secretary.resumeAtLaunch()
    }
  }
}
