import AppKit

/// ⌘T（worktree パレット）の提示と、決定から worktree の用意・タブの起動までの配線。
extension WindowController {
  /// Cmd+T・タブ行の「＋」。worktree パレット（worktree/branch から起動）を開く。
  /// git の一覧・フィルタ・⇥ 起動先切替（agent/shell）・⇧⇥ ベース切替・Enter 実行（worktree 解決＋
  /// 新タブ起動）・clean・最新化を配線する。
  ///
  /// パレットは **1 つの workspace** に結び付く。いつもは開いた時点の workspace、タスクから開いたとき
  /// （`task`）はそのタスクの workspace（解決できなければ開いた時点の workspace）。リポジトリを探す基点・
  /// タブを開く先・前回のベースの読み書き・worktree の作成先の設定は、どれもこの 1 つの workspace から引く
  /// ——作成中（fetch の着地待ちで数秒かかりうる）に別の workspace へ切り替わっても、別の workspace にタブが
  /// 開いたり、その「前回」が書き換わったりしない。タスクから開いたときは、タブを開いた後にその workspace
  /// とタブを前面にする。札を外したら（文脈を外したら）、いつもの ⌘T と同じく開いた時点の workspace と
  /// そのリポジトリへ結び付け直す（`returnWorktreePaletteToOpenedWorkspace`）。
  ///
  /// ↵ で worktree が用意できたら、タブを開く前に、決定の時点の文脈のタスクを進行中にしてその worktree を
  /// 付ける（`settleWorktreePalette`）。
  func showWorktreePalette(task taskID: Int? = nil) {
    if model.overlay == .worktreePalette {
      model.worktreePalette?.focus()
      return
    }
    let task = taskID.flatMap { id in taskStore.tasks.first { $0.id == id } }
    let binding = WorktreePaletteBinding(
      opened: current,
      workspace: task?.workspace.flatMap { id in workspaces.first { $0.persistentId == id } }
        ?? current,
      frontsWorkspace: task != nil)
    let p = WorktreePaletteModel(
      tasks: taskStore, githubItems: .shared, agents: worktreeAgents, task: task?.id)
    guard let provider = makeWorktreePaletteProvider(p, binding) else { return }
    p.setTargets(
      agents: agentLauncher.detectedAgents,
      defaultCommand: agentLauncher.resolvedDefaultCommand)
    p.onDismiss = { [weak self] in self?.dismissPalette() }

    // クロージャは兄弟パレット同様 [weak self] のみとし、p/provider は self.model 経由で辿る
    // （p が onExecute を保持するため、p を強参照すると開くたびに自己循環でリークする）。結び付いた
    // workspace は決定の時点で `binding` から読む（札を外すと結び付き直すため）。
    p.onExecute = { [weak self] destination in
      guard let self, let p = self.model.worktreePalette,
        let provider = self.model.worktreePaletteProvider
      else { return }
      // 作成中の再入を弾く（Enter 連打で git worktree add が二重に走るのを防ぐ）。
      guard !p.isPreparing else { return }
      // targets は常に非空（shell が常在）のため実質常に成立。非同期 completion で使うため値で capture する。
      // 文脈のタスクも決定の一部として、この時点の値で捕まえる（閉じた後にモデルを読まない）。
      guard let target = p.selectedTarget else { return }
      let launch = WorktreePaletteLaunch(target: target, task: p.task?.id, binding: binding)
      p.errorMessage = nil
      p.isPreparing = true  // 進捗表示 ON。非同期 worktree 作成の待機中だけフッターにスピナが出る。
      provider.prepareDirectory(for: destination) { [weak self] outcome in
        guard let self, let p = self.model.worktreePalette else { return }
        switch outcome {
        case .resolved(let resolution):
          self.settleWorktreePalette(resolution, launch)
        case .created(let path, let base):
          if let workspace = launch.workspace { self.rememberWorktreeBase(base, in: workspace) }
          self.settleWorktreePalette(.ready(path), launch)
        case .staleBranch(let sync, let relativeDate):
          // 作っていない。一覧の旗を下ろして最新化画面へ（以後の busy は画面の相が持つ）。
          p.isPreparing = false
          p.enterRefresh(sync: sync, relativeDate: relativeDate)
        }
      }
    }
    p.onCheckBranchName = { [weak self] name in
      self?.model.worktreePaletteProvider?.checkBranchName(name)
    }
    p.onTaskInputsChanged = { [weak self] in self?.model.worktreePaletteProvider?.rebuild() }
    p.onTaskContextCleared = { [weak self] in
      self?.returnWorktreePaletteToOpenedWorkspace(binding)
    }
    wireWorktreeClean(p, binding)
    wireWorktreePaletteRefresh(p, binding)

    model.worktreePalette = p
    model.worktreePaletteProvider = provider
    model.overlay = .worktreePalette
    provider.load()
    p.focus()
    reconfirmFocusNextTick()  // 別 overlay からの遷移で去りゆくカードの teardown に勝つ
  }

  /// 結び付いた workspace のリポジトリを読む provider（基点はその workspace のアクティブタブの cwd、0 タブなら
  /// root path）。workspace が既に消えていれば nil。
  private func makeWorktreePaletteProvider(
    _ p: WorktreePaletteModel, _ binding: WorktreePaletteBinding
  ) -> WorktreePaletteDataProvider? {
    guard let workspace = binding.workspace,
      let index = workspaces.firstIndex(where: { $0 === workspace })
    else { return nil }
    return WorktreePaletteDataProvider(
      cwd: store.newTabCwd(inWorkspaceAt: index), model: p, localization: localization,
      worktreeTemplate: settingsStore.effective(override: workspace.settingsOverride)[
        SettingKeys.worktreeDir],
      tabOccupancies: tabOccupancies(), previousBase: workspace.lastWorktreeBase)
  }

  /// 札を外した。開いた時点の workspace（消えていれば今の workspace）へ結び付け直し、前面化もやめる。
  /// タスクの workspace が別だったなら、そのリポジトリの一覧を捨てて、開いた時点の workspace のリポジトリを
  /// 読み直す（前の provider は切り離し、遅れて着地した読み取りがパレットを書かないようにする）。
  private func returnWorktreePaletteToOpenedWorkspace(_ binding: WorktreePaletteBinding) {
    binding.frontsWorkspace = false
    let opened = binding.opened ?? current
    guard opened !== binding.workspace, let p = model.worktreePalette else { return }
    binding.workspace = opened
    model.worktreePaletteProvider?.detach()
    p.discardRepositoryFacts()
    let provider = makeWorktreePaletteProvider(p, binding)
    model.worktreePaletteProvider = provider
    provider?.load()
  }

  /// 解決済みディレクトリで新タブを起こす唯一の 1 本（Enter の実行と clean の `o タブで開く` が共に通る）。
  /// 開く先はパレットが結び付いた workspace で、位置は実行時に引き直す。その workspace が既に消えていたら
  /// 開かない。`frontsWorkspace` なら、開いた後にその workspace と新しいタブを前面にする（`openTab` は背景の
  /// workspace には前面化せずに開く）。
  /// `dismissPalette()` ＋次 tick の `focusActiveTab()` の 2 点セットは、WorktreePaletteOverlay
  /// （focus を握る TextField 入り）の SwiftUI teardown が非同期で、同期のフォーカス確定の後に
  /// first responder を奪いうるという既知の事情への手当てなので、2 箇所に複製しない。
  private func openResolvedDirectory(
    _ dir: String, target: WorktreePaletteTarget, frontsWorkspace: Bool, in workspace: Workspace?
  ) {
    dismissPalette()
    guard let index = workspaces.firstIndex(where: { $0 === workspace }) else { return }
    let opened: OpenedTab?
    switch target {
    case .agent(let agent):
      opened = openTab(
        workspaceIndex: index, cwd: dir, command: agent.path,
        env: agentLauncher.launchEnvironment)
    case .shell:
      // command を渡さない＝既定シェル起動。
      opened = openTab(workspaceIndex: index, cwd: dir)
    }
    if frontsWorkspace, let opened { _ = controlFocusTab(tabId: opened.tabId) }
    DispatchQueue.main.async { [weak self] in self?.focusActiveTab() }
  }

  /// 解決の終端（一覧の Enter・最新化画面の 2 択が共に通る）。開けたら、文脈のタスクを進行中にして
  /// その worktree を付けてから（タスクが消えていたら何もしない）起動し、失敗はモデルが畳む——失敗の経路は
  /// タスクを変えない。
  private func settleWorktreePalette(
    _ resolution: WorktreePaletteDataProvider.DirectoryResolution, _ launch: WorktreePaletteLaunch
  ) {
    guard let p = model.worktreePalette else { return }
    switch resolution {
    case .ready(let dir):
      // 同期 .ready（既存 worktree 等）では true→dismiss が 1 tick で走り palette が破棄され無描画。
      p.isPreparing = false
      if let task = launch.task, let worktree = TaskWorktree(directory: dir) {
        _ = try? taskStore.begin(task, worktree: worktree)
      }
      openResolvedDirectory(
        dir, target: launch.target, frontsWorkspace: launch.frontsWorkspace,
        in: launch.workspace)
    case .failed(let message):
      p.failPreparation(message)
    }
  }

  /// 最新化画面の 2 択を配線する。手順（fetch → fast-forward → 作成）は provider が持ち、ここは
  /// 進行（作成が始まった）と終端をモデルへ流すだけ。
  private func wireWorktreePaletteRefresh(
    _ p: WorktreePaletteModel, _ binding: WorktreePaletteBinding
  ) {
    p.onSettleStale = { [weak self] choice, sync in
      guard let self, let p = self.model.worktreePalette,
        let provider = self.model.worktreePaletteProvider, let target = p.selectedTarget
      else { return }
      let launch = WorktreePaletteLaunch(target: target, task: p.task?.id, binding: binding)
      switch choice {
      case .asIs:
        provider.createLocalBranchWorktree(name: sync.name) { [weak self] resolution in
          self?.settleWorktreePalette(resolution, launch)
        }
      case .refreshed:
        provider.refreshAndCreate(
          sync, creating: { [weak self] in self?.model.worktreePalette?.refresh?.beginCreating() },
          completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure): self.model.worktreePalette?.refresh?.fail(failure)
            case .success(let resolution):
              self.settleWorktreePalette(resolution, launch)
            }
          })
      }
    }
  }

  /// clean の削除の駆動を配線する。1 件ごとの進捗をモデルへ流し、駆動が終わったら終端
  /// （失敗が無ければ一覧へ戻り、あれば一部失敗画面に留まる）はモデルが決める。
  private func wireWorktreeClean(_ p: WorktreePaletteModel, _ binding: WorktreePaletteBinding) {
    p.onCleanExecute = { [weak self] requests, token in
      guard let self, let provider = self.model.worktreePaletteProvider else { return }
      provider.deleteWorktrees(requests, token: token) { [weak self] progress in
        guard let clean = self?.model.worktreePalette?.clean else { return }
        switch progress {
        case .started(let path): clean.markRunning(path: path)
        case .finished(let path, let outcome): clean.markFinished(path: path, outcome: outcome)
        }
      } completion: { [weak self] in
        self?.model.worktreePalette?.settleCleanRun()
      }
    }
    // 失敗した worktree は解決済みのパスなので `prepareDirectory` を通さない。
    p.onOpenWorktree = { [weak self] path in
      guard let self, let p = self.model.worktreePalette, let target = p.selectedTarget else {
        return
      }
      self.openResolvedDirectory(
        path, target: target, frontsWorkspace: binding.frontsWorkspace, in: binding.workspace)
    }
  }

  /// 全 workspace × 全タブが開いているディレクトリ（休眠 workspace も含む）。
  /// 「そのパスをタブが開いている worktree は消せない」の判定材料。
  private func tabOccupancies() -> [TabOccupancy] {
    store.allTabs().map { TabOccupancy(cwd: $0.tab.cwd, agentState: $0.tab.agentState) }
  }
}

/// 開いている ⌘T が結び付いた workspace。タスクから開けばタスクの workspace で、札を外すと開いた時点の
/// workspace へ戻る。workspace は弱く持つ（開いている間に消えたら、タブを開かない）。
private final class WorktreePaletteBinding {
  /// ⌘T を開いた時点の workspace（いつもの ⌘T が結び付く先）。
  weak var opened: Workspace?
  weak var workspace: Workspace?
  /// 開いた後に、その workspace と新しいタブを前面にする。
  var frontsWorkspace: Bool

  init(opened: Workspace, workspace: Workspace, frontsWorkspace: Bool) {
    self.opened = opened
    self.workspace = workspace
    self.frontsWorkspace = frontsWorkspace
  }
}

/// ⌘T の決定（一覧の ↵・最新化画面の決定）の時点で捕まえる、起動の値。
private struct WorktreePaletteLaunch {
  let target: WorktreePaletteTarget
  /// 文脈のタスク。worktree が用意できたら、進行中にしてその worktree を付ける。
  let task: Int?
  weak var workspace: Workspace?
  /// 開いた後に、パレットが結び付いた workspace と新しいタブを前面にする。
  let frontsWorkspace: Bool

  init(target: WorktreePaletteTarget, task: Int?, binding: WorktreePaletteBinding) {
    self.target = target
    self.task = task
    workspace = binding.workspace
    frontsWorkspace = binding.frontsWorkspace
  }
}
