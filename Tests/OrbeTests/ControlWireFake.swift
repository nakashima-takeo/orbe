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
  /// `spawn` が返す新タブの ID。
  let spawnedTabId = 4242
  /// nil にすると `activate_workspace` が `-32004` になる。
  var activateResult: (activeWorkspaceId: UUID, tabIds: [Int])? = (
    activeWorkspaceId: FakeControlTarget.workspaceId, tabIds: []
  )
  /// 応答に載せる workspace の ID（`activate_workspace`・`create_workspace`・エージェントの起動）。
  static let workspaceId = UUID(uuidString: "0B5E4C3A-0000-4000-8000-000000000001")!
  /// 立てると `Result` を返す全メソッド（タブ操作・config・workspace CRUD）が
  /// これを `.failure` で返す。ドメインが決めるコード（tab 未発見の `-32004`・最後の
  /// workspace 削除の `-32000` 等）は `ControlServer` が生まず target から素通しするため、
  /// wire 側でその素通しを見るにはここを差し替えるしかない。
  var domainFailure: ControlError?

  /// 記録は常に行い、`domainFailure` が立っていればそれを、無ければ success を返す。
  func outcome(_ value: Any) -> Result<Any, ControlError> {
    if let failure = domainFailure { return .failure(failure) }
    return .success(value)
  }

  // MARK: - 記録

  struct ReadTrial {
    let trialId: Int
    let wait: Bool
    let timeoutMs: Int
  }

  struct ReportedAgent {
    let tabId: Int
    let agent: String
    let state: String
    let sessionId: String?
    let messageText: String?
    let messageSource: String?
    let reason: String?
    let reporterGroup: pid_t?
  }
  struct Spawn {
    let workspaceId: UUID?
    let cwd: String?
    let command: String?
    let selects: Bool
  }
  struct AgentSpawn {
    let command: String?
    let sessionId: String?
    let workspaceId: UUID?
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
    let workspaceId: UUID?
  }
  struct CreatedWorkspace {
    let name: String
    let rootPath: String?
  }
  struct RenamedWorkspace {
    let workspaceId: UUID
    let name: String
  }
  struct WorkspaceRoot {
    let workspaceId: UUID
    let rootPath: String
  }
  struct AddedTask {
    let draft: TaskDraft
    let workspaceId: ClearableValue<UUID>?
    let callerTabId: Int?
    let worktree: String?
  }
  struct UpdatedTask {
    let taskId: Int
    let update: TaskUpdate
    let workspaceId: ClearableValue<UUID>?
    let worktree: ClearableValue<String>?
  }
  struct SetWaitCondition {
    let taskId: Int
    let condition: ClearableValue<WaitConditionRequest>
    let callerTabId: Int?
  }

  private(set) var reportedAgents: [ReportedAgent] = []
  private(set) var spawns: [Spawn] = []
  private(set) var agentSpawns: [AgentSpawn] = []
  private(set) var prompts: [Prompt] = []
  private(set) var configSets: [ConfigSet] = []
  private(set) var configLists: [UUID?] = []
  private(set) var tabLists: [UUID?] = []
  private(set) var createdWorkspaces: [CreatedWorkspace] = []
  private(set) var renamedWorkspaces: [RenamedWorkspace] = []
  private(set) var workspaceRoots: [WorkspaceRoot] = []
  private(set) var removedWorkspaceIds: [UUID] = []
  private(set) var activatedWorkspaceIds: [UUID] = []
  private(set) var focusedTabIds: [Int] = []
  private(set) var openedFiles: [(tabId: Int, path: String)] = []
  private(set) var closedTabIds: [Int] = []
  private(set) var restoredSessionIds: [[String]] = []
  private(set) var taskLists: [UUID?] = []
  private(set) var addedTasks: [AddedTask] = []
  private(set) var updatedTasks: [UpdatedTask] = []
  private(set) var setWaitConditions: [SetWaitCondition] = []
  private(set) var deletedTaskIds: [Int] = []
  private(set) var startedTasks: [TaskStartRequest] = []
  private(set) var setAutomations: [FakeSetAutomation] = []
  private(set) var runLists: [FakeRunList] = []
  var runTools: [FakeRunTool] = []
  private(set) var ranAutomations: [(automationId: Int, nodeKey: String?)] = []
  private(set) var pausedAutomations: [FakePause] = []
  private(set) var deletedAutomationIds: [Int] = []
  private(set) var proposalLists: [Int?] = []
  var triedAutomations: [FakeTry] = []
  private(set) var readTrials: [ReadTrial] = []
  private(set) var boardLists: [UUID] = []
  private(set) var addedBoardWidgets: [(workspaceId: UUID, widget: BoardWidget)] = []
  private(set) var removedBoardWidgets: [(workspaceId: UUID, widget: BoardWidget)] = []

  // MARK: - 宛先

  /// 解決可能な唯一のタブ。id は `IdGen` のプロセス単調増加なので、テストは必ずここから読む。
  let tab = TerminalTab.alone(cwd: "/tmp")
  var tabId: Int { tab.id }

  func controlResolveTab(_ id: Int) -> TerminalTab? {
    id == tab.id ? tab : nil
  }

  // MARK: - ControlTarget

  func controlListWorkspaces() -> [[String: Any]] { workspaces }
  func controlListTabs(workspaceId: UUID?) -> Result<[[String: Any]], ControlError> {
    tabLists.append(workspaceId)
    if let failure = domainFailure { return .failure(failure) }
    return .success(tabs)
  }
  func controlListAgents() -> [[String: Any]] { agents }

  func controlSpawn(workspaceId: UUID?, cwd: String?, command: String?, selects: Bool)
    -> Result<Int, ControlError>
  {
    spawns.append(Spawn(workspaceId: workspaceId, cwd: cwd, command: command, selects: selects))
    if let failure = domainFailure { return .failure(failure) }
    return .success(spawnedTabId)
  }

  /// 起動結果。`command` 省略は codex（idle を報告しない agent）に解く——claude に解くと、
  /// 応答が ready 待ちに入り表駆動の往復が既定 30 秒を待つことになる。
  func controlSpawnAgent(command: String?, workspaceId: UUID?, cwd: String?) -> Result<
    AgentLaunch, ControlError
  > {
    agentSpawns.append(
      AgentSpawn(command: command, sessionId: nil, workspaceId: workspaceId, cwd: cwd))
    return launch(tabId: 4344, command: command ?? "codex")
  }

  func controlResumeAgent(command: String, sessionId: String, workspaceId: UUID?, cwd: String?)
    -> Result<AgentLaunch, ControlError>
  {
    agentSpawns.append(
      AgentSpawn(command: command, sessionId: sessionId, workspaceId: workspaceId, cwd: cwd))
    return launch(tabId: 4347, command: command)
  }

  private func launch(tabId: Int, command: String) -> Result<
    AgentLaunch, ControlError
  > {
    if let failure = domainFailure { return .failure(failure) }
    return .success(
      AgentLaunch(
        tabId: tabId, workspaceId: Self.workspaceId,
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

  func controlActivateWorkspace(workspaceId: UUID) -> (activeWorkspaceId: UUID, tabIds: [Int])? {
    activatedWorkspaceIds.append(workspaceId)
    return activateResult
  }

  func controlReportAgent(tab: TerminalTab, report: AgentHookReport) {
    reportedAgents.append(
      ReportedAgent(
        tabId: tab.id, agent: report.agent, state: report.state, sessionId: report.sessionId,
        messageText: report.message?.text, messageSource: report.message?.source,
        reason: report.reason, reporterGroup: report.reporterGroup))
  }

  func controlFocusTab(tabId: Int) -> Result<Any, ControlError> {
    focusedTabIds.append(tabId)
    return outcome(["ok": true])
  }

  func controlCloseTab(tabId: Int) -> Result<Any, ControlError> {
    closedTabIds.append(tabId)
    return outcome(["ok": true])
  }

  func controlOpenFile(tabId: Int, path: String) -> Result<Any, ControlError> {
    openedFiles.append((tabId, path))
    return outcome(["ok": true])
  }

  func controlConfigList(workspaceId: UUID?) -> Result<Any, ControlError> {
    configLists.append(workspaceId)
    return outcome(["settings": []])
  }

  func controlConfigSet(key: String, value: Any, scope: String, workspaceId: UUID?)
    -> Result<Any, ControlError>
  {
    configSets.append(ConfigSet(key: key, value: value, scope: scope, workspaceId: workspaceId))
    return outcome(["ok": true, "key": key, "value": value, "scope": scope])
  }

  func controlCreateWorkspace(name: String, rootPath: String?) -> Result<Any, ControlError> {
    createdWorkspaces.append(CreatedWorkspace(name: name, rootPath: rootPath))
    return outcome(
      ["workspaceId": Self.workspaceId.uuidString, "name": name, "rootPath": rootPath ?? "/tmp"])
  }

  func controlRenameWorkspace(workspaceId: UUID, name: String) -> Result<Any, ControlError> {
    renamedWorkspaces.append(RenamedWorkspace(workspaceId: workspaceId, name: name))
    return outcome(["ok": true])
  }

  func controlSetWorkspaceRoot(workspaceId: UUID, rootPath: String) -> Result<Any, ControlError> {
    workspaceRoots.append(WorkspaceRoot(workspaceId: workspaceId, rootPath: rootPath))
    return outcome(["ok": true])
  }

  func controlRemoveWorkspace(workspaceId: UUID) -> Result<Any, ControlError> {
    removedWorkspaceIds.append(workspaceId)
    return outcome(["ok": true])
  }

  func controlRestoreSessions(sessionIds: [String]) -> Result<Any, ControlError> {
    restoredSessionIds.append(sessionIds)
    return outcome(["results": sessionIds.map { ["sessionId": $0, "status": "restored"] }])
  }

  func controlListTasks(workspaceId: UUID?) -> Result<Any, ControlError> {
    taskLists.append(workspaceId)
    return outcome(["tasks": []])
  }

  func controlAddTask(
    _ draft: TaskDraft, workspaceId: ClearableValue<UUID>?, callerTabId: Int?, worktree: String?
  ) -> Result<Any, ControlError> {
    addedTasks.append(
      AddedTask(
        draft: draft, workspaceId: workspaceId, callerTabId: callerTabId, worktree: worktree))
    return outcome(["task": ["taskId": 1, "title": draft.title]])
  }

  func controlUpdateTask(
    taskId: Int, _ update: TaskUpdate, workspaceId: ClearableValue<UUID>?,
    worktree: ClearableValue<String>?
  ) -> Result<Any, ControlError> {
    updatedTasks.append(
      UpdatedTask(taskId: taskId, update: update, workspaceId: workspaceId, worktree: worktree))
    return outcome(["task": ["taskId": taskId]])
  }

  func controlSetWaitCondition(
    taskId: Int, _ condition: ClearableValue<WaitConditionRequest>, callerTabId: Int?
  ) -> Result<Any, ControlError> {
    setWaitConditions.append(
      SetWaitCondition(taskId: taskId, condition: condition, callerTabId: callerTabId))
    return outcome(["task": ["taskId": taskId]])
  }

  func controlDeleteTask(taskId: Int) -> Result<Any, ControlError> {
    deletedTaskIds.append(taskId)
    return outcome(["ok": true])
  }

  func controlStartTask(
    _ request: TaskStartRequest, completion: @escaping (Result<Any, ControlError>) -> Void
  ) {
    startedTasks.append(request)
    completion(outcome(["workdir": "/w"]))
  }

  func controlListAutomations() -> Result<Any, ControlError> {
    outcome(["automations": [Any]()])
  }

  func controlSetAutomation(
    automationId: Int?, version: Int?, _ definition: [String: Any]
  ) -> Result<
    Any, ControlError
  > {
    setAutomations.append(FakeSetAutomation(automationId, version, definition))
    return outcome(["automation": ["automationId": automationId ?? 1]])
  }

  func controlListAutomationRuns(automationId: Int, nodeKey: String?, before: Int?, limit: Int?)
    -> Result<Any, ControlError>
  {
    runLists.append(FakeRunList(nodeKey: nodeKey, before: before, limit: limit))
    return outcome(["runs": [Any]()])
  }

  func controlRunAutomation(automationId: Int, nodeKey: String?) -> Result<Any, ControlError> {
    ranAutomations.append((automationId, nodeKey))
    return outcome(["ok": true])
  }

  func controlPauseAutomation(automationId: Int, nodeKey: String?, paused: Bool) -> Result<
    Any, ControlError
  > {
    pausedAutomations.append(
      FakePause(automationId: automationId, nodeKey: nodeKey, paused: paused))
    return outcome(["automation": ["automationId": automationId]])
  }

  func controlDeleteAutomation(automationId: Int) -> Result<Any, ControlError> {
    deletedAutomationIds.append(automationId)
    return outcome(["ok": true])
  }

  func controlListAutomationProposals(automationId: Int?) -> Result<Any, ControlError> {
    proposalLists.append(automationId)
    return outcome(["proposals": [Any]()])
  }

  func controlAutomationTrial(
    trialId: Int, wait: Bool, timeoutMs: Int,
    completion: @escaping (Result<Any, ControlError>) -> Void
  ) {
    readTrials.append(ReadTrial(trialId: trialId, wait: wait, timeoutMs: timeoutMs))
    completion(outcome(["trial": [String: Any]()]))
  }
}

/// ボードのウィジェットの 3 動詞。
extension FakeControlTarget {
  func controlListBoardWidgets(workspaceId: UUID) -> Result<Any, ControlError> {
    boardLists.append(workspaceId)
    return outcome(["widgets": [["kind": "automation"]]])
  }

  func controlAddBoardWidget(workspaceId: UUID, widget: BoardWidget) -> Result<Any, ControlError> {
    addedBoardWidgets.append((workspaceId, widget))
    return outcome(["widgets": [["kind": "automation"]]])
  }

  func controlRemoveBoardWidget(workspaceId: UUID, widget: BoardWidget) -> Result<Any, ControlError>
  {
    removedBoardWidgets.append((workspaceId, widget))
    return outcome(["widgets": [Any]()])
  }
}
