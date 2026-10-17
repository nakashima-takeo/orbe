import Foundation

/// 秘書の係（`Secretary`）を窓に配線する。起こすタブは Home のフォルダで開く。
extension WindowController: SecretaryHost {
  var secretaryClaude: AgentCLI? {
    agentLauncher.detectedAgents.first { $0.command == "claude" }
  }

  /// 登録先の安定パスに実体化した同梱プラグインの名前。実体化していなければ（同梱の無い起動・隔離起動）nil。
  var secretaryPluginName: String? {
    AgentPluginInstaller.stablePluginDir.flatMap(AgentPluginInstaller.pluginName(in:))
  }

  func secretaryOpen(command: String) -> Bool {
    guard let index = store.homeIndex, let home = HomeFolder.url?.path,
      let opened = openTab(
        workspaceIndex: index, cwd: home, command: command, env: agentLauncher.launchEnvironment)
    else { return false }
    dismissPalette()
    _ = controlFocusTab(tabId: opened.tabId)
    return true
  }
}
