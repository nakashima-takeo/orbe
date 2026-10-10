import Foundation

/// タスクから作業を始める（`start_task`）。タスクの付き先で作業場の用意が分かれ——リポジトリの workspace のタスクは
/// ⌘T の「タスクから開く」と同じ規則で worktree（`TaskRepoWorktree`）、Home のタスクは Home の中のタスクごとの
/// フォルダ（`HomeTaskFolder`）——その後は同じ。⌘T と同じ `TaskStore.begin` でタスクを進行中にして作業場を付け、
/// タスクの workspace に agent のタブを選ばずに起こす。
extension WindowController {
  func controlStartTask(
    _ request: TaskStartRequest, completion: @escaping (Result<Any, ControlError>) -> Void
  ) {
    guard let task = taskStore.tasks.first(where: { $0.id == request.taskId }) else {
      return completion(.failure(Self.taskNotFound(request.taskId)))
    }
    guard
      let workspace = task.workspace.flatMap({ id in workspaces.first { $0.persistentId == id } }),
      let index = workspaces.firstIndex(where: { $0 === workspace })
    else {
      return completion(
        .failure(
          ControlError(
            code: -32602,
            message: "task \(task.id) has no workspace; attach one with update_task first")))
    }
    let settings = settingsStore.effective(override: workspace.settingsOverride)
    let command =
      request.agent
      ?? AgentLauncher.resolveDefault(
        configured: settings[SettingKeys.defaultAgent], detected: agentLauncher.detectedCommands)
    guard let agent = agentLauncher.detectedAgents.first(where: { $0.command == command }) else {
      return completion(
        .failure(ControlError(code: -32602, message: "agent not detected: \(command ?? "none")")))
    }
    let begin = { [weak self] (result: Result<TaskWorkplace, TaskStartFailure>, input: String?) in
      guard let self else { return }
      switch result {
      case .failure(let failure):
        completion(.failure(failure.controlError))
      case .success(let workplace):
        completion(
          self.beginTaskWork(
            task.id, in: workspace.persistentId, at: workplace, agent: agent, firstInput: input))
      }
    }
    let prompt = request.prompt.flatMap { $0.isEmpty ? nil : $0 }
    if store.isHome(index) {
      begin(
        prepareHomeTaskFolder(task),
        TaskStartText.homeFirstInput(task, prompt: prompt, l10n: localization))
      return
    }
    let candidates: [String]
    switch repositoryCandidates(task, repo: request.repo, root: workspace.rootPath) {
    case .success(let found): candidates = found
    case .failure(let error): return completion(.failure(error))
    }
    let localization = localization
    let template = settings[SettingKeys.worktreeDir]
    TaskRepoWorktree(
      task: task, branch: request.branch, candidates: candidates, items: .shared,
      makeFacts: {
        WorktreeRepoFacts(cwd: $0, localization: localization, worktreeTemplate: template)
      }
    ).start { begin($0, prompt) }
  }

  /// リポジトリを探す場所（順に試す）。タスクの worktree があればそれ、無ければ `repo`（リポジトリの中の絶対パス）、
  /// 最後に workspace の root。
  private func repositoryCandidates(_ task: TaskItem, repo: String?, root: String) -> Result<
    [String], ControlError
  > {
    if let worktree = task.worktree, worktree.exists { return .success([worktree.path, root]) }
    guard let repo else { return .success([root]) }
    var isDirectory: ObjCBool = false
    guard repo.hasPrefix("/"),
      FileManager.default.fileExists(atPath: repo, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return .failure(
        ControlError(code: -32602, message: "repo is not an absolute path to a directory: \(repo)"))
    }
    return .success([repo, root])
  }

  /// Home のタスクの作業場を用意する（無ければ作る）。Home が git の中にあると作業場の一致が崩れるので拒む。
  func prepareHomeTaskFolder(_ task: TaskItem) -> Result<TaskWorkplace, TaskStartFailure> {
    guard let home = HomeFolder.url?.path else { return .failure(.failed("Home is unresolved")) }
    guard !HomeTaskFolder.isInsideGit(home: home) else {
      return .failure(.failed("Home is inside a git repository: \(home)"))
    }
    let path = HomeTaskFolder.path(for: task, home: home)
    do {
      return .success(TaskWorkplace(path: path, created: try HomeTaskFolder.prepare(path)))
    } catch {
      return .failure(.failed("cannot create \(path): \(error.localizedDescription)"))
    }
  }

  /// 用意できた作業場でタスクを進行中にして付け、agent のタブを選ばずに起こす。用意の間にタスクか workspace が
  /// 消えていれば、タブは起こさない。
  private func beginTaskWork(
    _ taskId: Int, in workspaceId: UUID, at workplace: TaskWorkplace, agent: AgentCLI,
    firstInput: String?
  ) -> Result<Any, ControlError> {
    guard let worktree = TaskWorktree(directory: workplace.path) else {
      return .failure(ControlError(code: -32000, message: "not a directory: \(workplace.path)"))
    }
    guard let index = workspaces.firstIndex(where: { $0.persistentId == workspaceId }) else {
      return .failure(ControlError(code: -32000, message: "the task's workspace was removed"))
    }
    do {
      try taskStore.begin(taskId, worktree: worktree)
    } catch {
      return .failure(Self.taskNotFound(taskId))
    }
    guard
      let task = taskStore.tasks.first(where: { $0.id == taskId }),
      let opened = openTab(
        workspaceIndex: index, cwd: worktree.path,
        command: AgentCatalog.startCommand(agent, firstInput: firstInput),
        env: agentLauncher.launchEnvironment, agent: agent.command, selects: false)
    else { return .failure(ControlError(code: -32000, message: "spawn failed")) }
    var result: [String: Any] = [
      "task": taskJSON(task), "workdir": worktree.path, "created": workplace.created,
      "tabId": opened.tabId, "workspaceId": opened.workspaceId,
      "agent": ["command": agent.command, "path": agent.path],
    ]
    if let repo = workplace.repo { result["repo"] = repo }
    if let branch = worktree.currentBranch { result["branch"] = branch }
    return .success(result)
  }

  private static func taskNotFound(_ id: Int) -> ControlError {
    ControlError(code: -32004, message: "task not found: \(id)")
  }
}
