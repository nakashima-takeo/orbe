import AppKit

/// ⌘⇧X タスク画面の提示。画面はタスクと受信のストア（唯一の正）を直接読み書きし、ここは開いた時点の
/// workspace の写しと GitHub タブのリポジトリの基点、GitHub の値の置き場、受信の走らせ役を渡して配線するだけ。
extension WindowController {
  /// タスク画面を開く（開いていれば焦点をモデルが決めた行き先へ当て直すだけ）。タブが 0 枚の workspace でも開く。
  /// GitHub タブの一覧は、タスクのタブを開いていても取り直す（ヘッダーの「GitHub N」のため）。
  func showTaskPalette() {
    if model.overlay == .taskPalette {
      model.taskPalette?.focus()
      return
    }
    // GitHub タブのリポジトリは ⌘T と同じ基点で決める（「⌘T タスクにして開く」が同じリポジトリを開くため）。
    let base = store.newTabCwd(inWorkspaceAt: store.activeWorkspace)
    let entry = { (ws: Workspace) in
      TaskPaletteWorkspaces.Entry(id: ws.persistentId, name: ws.name)
    }
    let p = TaskPaletteModel(
      store: taskStore, githubItems: .shared, viewer: .shared, openLists: .shared,
      root: base, agents: worktreeAgents, sessionTabs: agentSessionTabs, intakes: intakeRunner,
      workspaces: TaskPaletteWorkspaces(
        opened: entry(current), all: workspaces.map(entry), home: store.homeWorkspaceId),
      now: Date(), timeZone: .current)
    p.onDismiss = { [weak self] in self?.dismissPalette() }
    p.onOpenURL = { NSWorkspace.shared.open($0) }
    p.onOpenWorktreePalette = { [weak self] id in self?.openWorktreePalette(forTask: id) }
    p.onFocusTab = { [weak self] tabId in
      self?.dismissPalette()
      _ = self?.controlFocusTab(tabId: tabId)
    }
    p.onContinueWait = { [weak self] id in self?.continueWait(taskId: id) }
    p.continuationBlock = { [weak self] id in self?.continuationBlock(taskId: id) }
    p.onAskSecretary = { [weak self] ask in
      guard let self else { return .failure(.claudeMissing) }
      do throws(Secretary.Refusal) {
        return .success(try self.secretary.ask(ask))
      } catch {
        return .failure(error)
      }
    }
    model.taskPalette = p
    model.overlay = .taskPalette
    p.focus()
    reconfirmFocusNextTick()  // 別 overlay からの遷移で去りゆくカードの teardown に勝つ
    GitHubOpenLists.shared.open(root: base)
    linkPullRequestsFromBranches()
  }

  /// PR の自動の結び付け（⌘⇧X を開いたとき）。完了していないタスクの、実在する worktree のブランチの PR を、
  /// そのタスクの結び付きの末尾に足す。worktree での作業のブランチが確定していれば、そのブランチにいる間だけ
  /// 引く（ブランチを切り替えて使い回す main worktree で、別の作業の PR を足さない）。未確定（無い・既定
  /// ブランチ）なら今のブランチで引き、既定ブランチ以外にいればそのブランチで確定する。人が外した項目・既に
  /// どこかに付いている項目は足さない（`TaskStore.linkFromBranch`）。答えが届くまでに worktree が別のタスクへ
  /// 移っていれば、今の持ち主の記録が引いたときと同じときだけ、その持ち主に足す。
  private func linkPullRequestsFromBranches() {
    var worktrees: [String: String?] = [:]
    for task in taskStore.tasks where task.status != .done {
      guard let worktree = task.worktree, worktree.exists else { continue }
      worktrees[worktree.path] = task.worktreeBranch
    }
    guard !worktrees.isEmpty else { return }
    WorktreePullRequestResolver().resolve(worktrees: worktrees) { [weak self] found in
      guard let self else { return }
      for (path, match) in found {
        guard
          let task = self.taskStore.tasks.first(where: { $0.worktree?.path == path }),
          worktrees[path] == .some(task.worktreeBranch)
        else { continue }
        self.taskStore.confirmWorktreeBranch(task.id, path: path, branch: match.branch)
        if let item = match.pullRequest {
          self.taskStore.linkFromBranch(task.id, TaskLink(item: item, kind: .pr))
        }
      }
    }
  }

  /// タスク画面の ⌘T。タスク画面を確定して畳み、そのタスクのための ⌘T に差し替える。
  func openWorktreePalette(forTask id: Int) {
    settleTaskPaletteEditing()
    model.taskPalette = nil
    showWorktreePalette(task: id)
  }

  /// タスク画面で打ちかけの編集を確定する。画面を閉じる・別の画面へ差し替わる・アプリの終了の
  /// どれでも、打った内容を失わない。
  func settleTaskPaletteEditing() {
    model.taskPalette?.leaveEditing()
  }
}
