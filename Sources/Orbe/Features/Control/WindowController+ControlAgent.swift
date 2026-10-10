import AppKit

/// 制御チャネルのエージェント起動（`spawn_agent` / `resume_agent`）。どちらも GUI の
/// Cmd+Shift+A / Cmd+Shift+C と同じ経路（`openTab` ＋ 解決済み絶対パス ＋ login shell の PATH）を
/// 通る——起動のされ方が経路ごとに割れると、「GUI からは動くが CLI からは動かない」という形で
/// 後から必ず出る。
extension WindowController {
  /// 検出済みエージェントを新タブで起こす（制御 API の spawn_agent）。command 省略時は対象
  /// workspace の実効 `default-agent` を `AgentLauncher.resolveDefault` で解く（GUI の Cmd+Shift+C
  /// と同じ 1 規則。違うのは入力がアクティブ WS ではなく**対象 WS** の実効設定であることだけ）。
  func controlSpawnAgent(command: String?, workspaceId: Int?, cwd: String?) -> Result<
    AgentLaunch, ControlError
  > {
    resolveAgentLaunch(command: command, workspaceId: workspaceId).flatMap { target in
      launchAgentTab(target, command: target.agent.path, cwd: cwd)
    }
  }

  /// 既存セッションを resume してエージェントを新タブで起こす（制御 API の resume_agent）。再開は休眠のタブの起床と
  /// 同じ組み立て（`openResumedTab`）を通る——秘書の会話なら秘書の役割の指示も添える。その会話が既に生きているタブで
  /// 開いていれば、新しく起こさずそのタブを返す（同じ会話を 2 つの claude が同時に書くと記録が混ざる）。
  func controlResumeAgent(command: String, sessionId: String, workspaceId: Int?, cwd: String?)
    -> Result<AgentLaunch, ControlError>
  {
    resolveAgentLaunch(command: command, workspaceId: workspaceId).flatMap { target in
      guard AgentCatalog.isSafeSessionId(sessionId) else {
        return .failure(ControlError(code: -32602, message: "invalid sessionId"))
      }
      let session = AgentSession(command: target.agent.command, sessionId: sessionId)
      if let open = store.allTabs().first(where: {
        !$0.tab.isDormant && $0.tab.agentSlot.session == session
      }) {
        let state = open.tab.agentState
        return .success(
          AgentLaunch(
            tabId: open.tab.id, workspaceId: workspaces[open.workspaceIndex].id,
            agent: target.agent, readyAsOpened: state == "idle" || state == "done"))
      }
      guard
        let opened = openResumedTab(
          session, workspaceIndex: target.workspaceIndex, cwd: cwd)
      else {
        return .failure(ControlError(code: -32000, message: "spawn failed"))
      }
      return .success(
        AgentLaunch(tabId: opened.tabId, workspaceId: opened.workspaceId, agent: target.agent))
    }
  }

  /// `spawn_agent` / `resume_agent` が共有する解決結果（起動先 workspace と起動する agent）。
  private struct AgentLaunchTarget {
    let workspaceIndex: Int
    let agent: AgentCLI
  }

  /// 対象 workspace と agent を解決する。workspaceId 未知は -32004、未検出 command は -32602、
  /// デフォルトが解けない（検出ゼロ）は -32000。
  private func resolveAgentLaunch(command: String?, workspaceId: Int?) -> Result<
    AgentLaunchTarget, ControlError
  > {
    let index: Int
    if let workspaceId {
      guard let found = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
        return .failure(ControlError(code: -32004, message: "workspace not found"))
      }
      index = found
    } else {
      index = activeWorkspace
    }

    if let command {
      guard let agent = agentLauncher.detectedAgents.first(where: { $0.command == command }) else {
        return .failure(
          ControlError(code: -32602, message: "agent not detected: \(command)"))
      }
      return .success(AgentLaunchTarget(workspaceIndex: index, agent: agent))
    }

    let configured = settingsStore.effective(override: workspaces[index].settingsOverride)[
      SettingKeys.defaultAgent]
    guard
      let resolved = AgentLauncher.resolveDefault(
        configured: configured, detected: agentLauncher.detectedCommands),
      let agent = agentLauncher.detectedAgents.first(where: { $0.command == resolved })
    else {
      return .failure(ControlError(code: -32000, message: "no agent detected"))
    }
    return .success(AgentLaunchTarget(workspaceIndex: index, agent: agent))
  }

  /// 解決済みの起動先へ 1 タブ起こす。env は `AgentLauncher.launchEnvironment`（login shell の
  /// PATH）で、GUI 起動と同じ解決をエージェントの子プロセスにも保証する。
  private func launchAgentTab(_ target: AgentLaunchTarget, command: String, cwd: String?) -> Result<
    AgentLaunch, ControlError
  > {
    guard
      let opened = openTab(
        workspaceIndex: target.workspaceIndex, cwd: cwd, command: command,
        env: agentLauncher.launchEnvironment)
    else {
      return .failure(ControlError(code: -32000, message: "spawn failed"))
    }
    return .success(
      AgentLaunch(tabId: opened.tabId, workspaceId: opened.workspaceId, agent: target.agent))
  }
}
