import AppKit
import Foundation

@testable import Orbe

/// `ControlTarget` の Fake。受け取った引数を記録し、ドメインは一切実行しない。
///
/// 記録するのは `ControlServer` が params から取り出して**渡した値**なので、`-32602` ガードの
/// 無い optional param（`messageSource` 等）の到達もここでしか観測できない。
///
/// 宛先解決に使う `pane` は実 `SurfaceView` だが、window に載せないので libghostty surface は
/// 生まれない（surface を作るのは `viewDidMoveToWindow`）。制御系のメソッドは surface 不在で
/// no-op / nil を返すため、L3 は L2 の重さを背負わずに宛先解決の経路だけを通せる。
final class FakeControlTarget: ControlTarget {
  // MARK: - 返り値（テストが決める）

  var workspaces: [[String: Any]] = []
  var panes: [[String: Any]] = []
  var agents: [[String: Any]] = []
  /// nil にすると `spawn` が `-32000`（spawn failed）になる。
  var spawnedPaneId: Int? = 4242
  /// nil にすると `activate_workspace` が `-32004` になる。
  var activateResult: (activeWorkspaceId: Int, paneIds: [Int])? = (
    activeWorkspaceId: 1, paneIds: []
  )
  /// 立てると `Result` を返す全メソッド（ペイン/タブ操作・config・workspace CRUD）が
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
    let paneId: Int
    let agent: String
    let state: String
    let sessionId: String?
    let messageText: String?
    let messageSource: String?
  }
  struct Spawn {
    let workspaceId: Int?
    let cwd: String?
    let command: String?
  }
  struct Split {
    let paneId: Int
    let direction: String
    let command: String?
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
  private(set) var splits: [Split] = []
  private(set) var configSets: [ConfigSet] = []
  private(set) var configLists: [Int?] = []
  private(set) var createdWorkspaces: [CreatedWorkspace] = []
  private(set) var renamedWorkspaces: [RenamedWorkspace] = []
  private(set) var workspaceRoots: [WorkspaceRoot] = []
  private(set) var removedWorkspaceIds: [Int] = []
  private(set) var activatedWorkspaceIds: [Int] = []
  private(set) var closedPaneIds: [Int] = []
  private(set) var focusedPaneIds: [Int] = []
  private(set) var closedTabIds: [Int] = []
  private(set) var resolvedPaneIds: [Int] = []

  // MARK: - 宛先

  /// 解決可能な唯一のペイン。id は `IdGen` のプロセス単調増加なので、テストは必ずここから読む。
  let pane = SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
  var paneId: Int { pane.id }

  func controlResolvePane(_ id: Int) -> SurfaceView? {
    resolvedPaneIds.append(id)
    return id == pane.id ? pane : nil
  }

  // MARK: - ControlTarget

  func controlListWorkspaces() -> [[String: Any]] { workspaces }
  func controlListPanes() -> [[String: Any]] { panes }
  func controlListAgents() -> [[String: Any]] { agents }

  func controlSpawn(workspaceId: Int?, cwd: String?, command: String?) -> Int? {
    spawns.append(Spawn(workspaceId: workspaceId, cwd: cwd, command: command))
    return spawnedPaneId
  }

  func controlActivateWorkspace(workspaceId: Int) -> (activeWorkspaceId: Int, paneIds: [Int])? {
    activatedWorkspaceIds.append(workspaceId)
    return activateResult
  }

  func controlReportAgent(
    pane: SurfaceView, agent: String, state: String, sessionId: String?, message: AgentMessage?
  ) {
    reportedAgents.append(
      ReportedAgent(
        paneId: pane.id, agent: agent, state: state, sessionId: sessionId,
        messageText: message?.text, messageSource: message?.source))
  }

  func controlSplitPane(paneId: Int, direction: String, command: String?)
    -> Result<Any, ControlError>
  {
    splits.append(Split(paneId: paneId, direction: direction, command: command))
    return outcome(["paneId": 5151])
  }

  func controlClosePane(paneId: Int) -> Result<Any, ControlError> {
    closedPaneIds.append(paneId)
    return outcome(["ok": true])
  }

  func controlFocusPane(paneId: Int) -> Result<Any, ControlError> {
    focusedPaneIds.append(paneId)
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
