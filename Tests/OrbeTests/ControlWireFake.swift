import AppKit
import Foundation

@testable import Orbe

/// `ControlTarget` の Fake。受け取った引数を記録し、ドメインは一切実行しない。
///
/// 記録するのは `ControlServer` が params から取り出して**渡した値**なので、`-32602` ガードの
/// 無い optional param（`messageSource` 等）の到達もここでしか観測できない。
///
/// 宛先解決に使う `tab` は実 `TerminalTab` だが、window に載せないので libghostty surface は
/// 生まれない（surface を作るのは `viewDidMoveToWindow`）。制御系のメソッドは surface 不在で
/// no-op / nil を返すため、L3 は L2 の重さを背負わずに宛先解決の経路だけを通せる。
final class FakeControlTarget: ControlTarget {
  // MARK: - 返り値（テストが決める）

  var workspaces: [[String: Any]] = []
  var tabs: [[String: Any]] = []
  var agents: [[String: Any]] = []
  /// nil にすると `spawn` が `-32000`（spawn failed）になる。
  var spawnedTabId: Int? = 4242
  /// nil にすると `activate_workspace` が `-32004` になる。
  var activateResult: (activeWorkspaceId: Int, tabIds: [Int])? = (
    activeWorkspaceId: 1, tabIds: []
  )
  /// 立てると `Result` を返す全メソッド（タブ操作・config・workspace CRUD）が
  /// これを `.failure` で返す。ドメインが決めるコード（tab 未発見の `-32004`・最後の
  /// workspace 削除の `-32000` 等）は `ControlServer` が生まず target から素通しするため、
  /// wire 側でその素通しを見るにはここを差し替えるしかない。
  var domainFailure: ControlError?

  /// 記録は常に行い、`domainFailure` が立っていればそれを、無ければ success を返す。
  private func outcome(_ value: Any) -> Result<Any, ControlError> {
    if let failure = domainFailure { return .failure(failure) }
    return .success(value)
  }

  // MARK: - 記録

  struct ReportedAgent {
    let tabId: Int
    let agent: String
    let state: String
    let sessionId: String?
    let messageText: String?
    let messageSource: String?
    let reason: String?
  }
  struct Spawn {
    let workspaceId: Int?
    let cwd: String?
    let command: String?
  }
  struct AgentSpawn {
    let command: String?
    let sessionId: String?
    let workspaceId: Int?
    let cwd: String?
  }
  struct Prompt {
    let tabId: Int
    let text: String
  }
  struct ConfigSet {
    let key: String
    let value: Any
    let scope: String
    let workspaceId: Int?
  }
  struct CreatedWorkspace {
    let name: String
    let rootPath: String?
  }
  struct RenamedWorkspace {
    let workspaceId: Int
    let name: String
  }
  struct WorkspaceRoot {
    let workspaceId: Int
    let rootPath: String
  }

  private(set) var reportedAgents: [ReportedAgent] = []
  private(set) var spawns: [Spawn] = []
  private(set) var agentSpawns: [AgentSpawn] = []
  private(set) var prompts: [Prompt] = []
  private(set) var configSets: [ConfigSet] = []
  private(set) var configLists: [Int?] = []
  private(set) var createdWorkspaces: [CreatedWorkspace] = []
  private(set) var renamedWorkspaces: [RenamedWorkspace] = []
  private(set) var workspaceRoots: [WorkspaceRoot] = []
  private(set) var removedWorkspaceIds: [Int] = []
  private(set) var activatedWorkspaceIds: [Int] = []
  private(set) var focusedTabIds: [Int] = []
  private(set) var closedTabIds: [Int] = []
  private(set) var resolvedTabIds: [Int] = []

  // MARK: - 宛先

  /// 解決可能な唯一のタブ。id は `IdGen` のプロセス単調増加なので、テストは必ずここから読む。
  let tab = TerminalTab(cwd: "/tmp")
  var tabId: Int { tab.id }

  func controlResolveTab(_ id: Int) -> TerminalTab? {
    resolvedTabIds.append(id)
    return id == tab.id ? tab : nil
  }

  // MARK: - ControlTarget

  func controlListWorkspaces() -> [[String: Any]] { workspaces }
  func controlListTabs() -> [[String: Any]] { tabs }
  func controlListAgents() -> [[String: Any]] { agents }

  func controlSpawn(workspaceId: Int?, cwd: String?, command: String?) -> Int? {
    spawns.append(Spawn(workspaceId: workspaceId, cwd: cwd, command: command))
    return spawnedTabId
  }

  /// 起動結果。`command` 省略は codex（idle を報告しない agent）に解く——claude に解くと、
  /// 応答が ready 待ちに入り表駆動の往復が既定 30 秒を待つことになる。
  func controlSpawnAgent(command: String?, workspaceId: Int?, cwd: String?) -> Result<
    AgentLaunch, ControlError
  > {
    agentSpawns.append(
      AgentSpawn(command: command, sessionId: nil, workspaceId: workspaceId, cwd: cwd))
    return launch(tabId: 4344, workspaceId: 4345, command: command ?? "codex")
  }

  func controlResumeAgent(command: String, sessionId: String, workspaceId: Int?, cwd: String?)
    -> Result<AgentLaunch, ControlError>
  {
    agentSpawns.append(
      AgentSpawn(command: command, sessionId: sessionId, workspaceId: workspaceId, cwd: cwd))
    return launch(tabId: 4347, workspaceId: 4348, command: command)
  }

  private func launch(tabId: Int, workspaceId: Int, command: String) -> Result<
    AgentLaunch, ControlError
  > {
    if let failure = domainFailure { return .failure(failure) }
    return .success(
      AgentLaunch(
        tabId: tabId, workspaceId: workspaceId,
        agent: AgentCLI(command: command, path: "/fake/bin/\(command)")))
  }

  /// 送信が引き起こす遷移の代役。実経路では hook → `report_agent` → main hop → didSet → emit と
  /// 戻ってくるので、テストはここで `DispatchQueue.main.async { emit }` のように同じ順序で流す。
  var promptSideEffect: (() -> Void)?

  /// `prompt_agent` の到達記録。`domainFailure` が立っていればそれで拒み、無ければ送れたことにする
  /// （surface 不在で `controlSendText` は no-op なので、実 `WindowController` 経路は L4 が測る）。
  func controlPromptAgent(tab: TerminalTab, text: String) -> ControlError? {
    prompts.append(Prompt(tabId: tab.id, text: text))
    if let failure = domainFailure { return failure }
    promptSideEffect?()
    return nil
  }

  func controlActivateWorkspace(workspaceId: Int) -> (activeWorkspaceId: Int, tabIds: [Int])? {
    activatedWorkspaceIds.append(workspaceId)
    return activateResult
  }

  func controlReportAgent(tab: TerminalTab, report: AgentHookReport) {
    reportedAgents.append(
      ReportedAgent(
        tabId: tab.id, agent: report.agent, state: report.state, sessionId: report.sessionId,
        messageText: report.message?.text, messageSource: report.message?.source,
        reason: report.reason))
  }

  func controlFocusTab(tabId: Int) -> Result<Any, ControlError> {
    focusedTabIds.append(tabId)
    return outcome(["ok": true])
  }

  func controlCloseTab(tabId: Int) -> Result<Any, ControlError> {
    closedTabIds.append(tabId)
    return outcome(["ok": true])
  }

  func controlConfigList(workspaceId: Int?) -> Result<Any, ControlError> {
    configLists.append(workspaceId)
    return outcome(["settings": []])
  }

  func controlConfigSet(key: String, value: Any, scope: String, workspaceId: Int?)
    -> Result<Any, ControlError>
  {
    configSets.append(ConfigSet(key: key, value: value, scope: scope, workspaceId: workspaceId))
    return outcome(["ok": true, "key": key, "value": value, "scope": scope])
  }

  func controlCreateWorkspace(name: String, rootPath: String?) -> Result<Any, ControlError> {
    createdWorkspaces.append(CreatedWorkspace(name: name, rootPath: rootPath))
    return outcome(["workspaceId": 7, "name": name, "rootPath": rootPath ?? "/tmp"])
  }

  func controlRenameWorkspace(workspaceId: Int, name: String) -> Result<Any, ControlError> {
    renamedWorkspaces.append(RenamedWorkspace(workspaceId: workspaceId, name: name))
    return outcome(["ok": true])
  }

  func controlSetWorkspaceRoot(workspaceId: Int, rootPath: String) -> Result<Any, ControlError> {
    workspaceRoots.append(WorkspaceRoot(workspaceId: workspaceId, rootPath: rootPath))
    return outcome(["ok": true])
  }

  func controlRemoveWorkspace(workspaceId: Int) -> Result<Any, ControlError> {
    removedWorkspaceIds.append(workspaceId)
    return outcome(["ok": true])
  }
}
