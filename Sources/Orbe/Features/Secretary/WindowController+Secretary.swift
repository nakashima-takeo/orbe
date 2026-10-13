import Foundation

/// 秘書の係（`Secretary`）を窓に配線する。起こすタブは Home のフォルダで開く。
extension WindowController: SecretaryHost {
  var secretaryClaude: AgentCLI? {
    agentLauncher.detectedAgents.first { $0.command == "claude" }
  }

  func secretaryOpen(command: String, shows: Bool) -> Bool {
    guard let index = store.homeIndex, let home = HomeFolder.url?.path,
      let opened = openTab(
        workspaceIndex: index, cwd: home, command: command, env: agentLauncher.launchEnvironment,
        selects: shows)
    else { return false }
    if shows {
      dismissPalette()
      _ = controlFocusTab(tabId: opened.tabId)
    }
    return true
  }
}
