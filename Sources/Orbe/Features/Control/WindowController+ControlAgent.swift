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
    Any, ControlError
  > {
    resolveAgentLaunch(command: command, workspaceId: workspaceId).flatMap { target in
      launchAgentTab(target, command: target.agent.path, cwd: cwd)
    }
  }

  /// 既存セッションを resume してエージェントを新タブで起こす（制御 API の resume_agent）。
  /// 起動文字列は `AgentCatalog.resumeCommand`（sessionId の安全文字検証込み）が組む——永続復元の
  /// resume（`AgentLauncher.resumeSpawn`）と同一の形で、login PATH 注入により bare 名で解決する。
  func controlResumeAgent(command: String, sessionId: String, workspaceId: Int?, cwd: String?)
    -> Result<Any, ControlError>
  {
    resolveAgentLaunch(command: command, workspaceId: workspaceId).flatMap { target in
      // ここへ来た時点で command は検出済み＝`AgentCatalog.supported` のいずれかなので、
      // nil になるのは sessionId が安全文字集合の外にあるときに限られる。
      guard
        let resume = AgentCatalog.resumeCommand(
          forAgent: target.agent.command, sessionId: sessionId)
      else {
        return .failure(ControlError(code: -32602, message: "invalid sessionId"))
      }
      return launchAgentTab(target, command: resume, cwd: cwd)
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
    Any, ControlError
  > {
    guard
      let opened = openTab(
        workspaceIndex: target.workspaceIndex, cwd: cwd, command: command,
        env: agentLauncher.launchEnvironment)
    else {
      return .failure(ControlError(code: -32000, message: "spawn failed"))
    }
    return .success([
      "paneId": opened.paneId, "tabId": opened.tabId, "workspaceId": opened.workspaceId,
      "agent": ["command": target.agent.command, "path": target.agent.path],
    ])
  }
}
