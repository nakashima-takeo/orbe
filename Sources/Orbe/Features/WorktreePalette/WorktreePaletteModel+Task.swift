import Foundation

/// worktree の行に出すタスク（その worktree を持つタスク）と、その worktree で動く agent。
struct WorktreePaletteRowTask: Equatable {
  let task: TaskItem
  let agent: WorktreeAgentActivity.Agent?
}

/// ↵ がタスクに起こすこと（フッターが ↵ の説明の後に言う）。
struct WorktreePaletteTaskEffect: Equatable {
  let task: TaskItem
  /// 進行中にする（未着手・完了のタスク）。
  let begins: Bool
  /// 選んだ worktree を今持っている別のタスク（そこから付け替える）。
  let previousOwner: TaskItem?
}

/// タスクの文脈と、worktree の行のタスク。どれも描くたびにストアから引く。
extension WorktreePaletteModel {
  /// 文脈のタスク（無い・消えたなら nil）。
  var task: TaskItem? {
    taskContextID.flatMap { id in tasks.tasks.first { $0.id == id } }
  }

  /// 先頭の欄の解決に要る、⌘T の外の値の写し。
  var taskInputs: WorktreePaletteTaskInputs {
    WorktreePaletteTaskInputs(task: task, items: githubItems)
  }

  /// 主が PR なら、その値（head のブランチ）を、この開いている間にまだ試していなければ取りに行く。届くまで
  /// 先頭の欄は決まらず ↵ は預かるので、頼まないと預かりが解けない。
  func ensurePrimaryPullRequest() {
    guard let primary = task?.links.first, primary.kind == .pr else { return }
    githubItems.ensure([primary.item])
  }

  func rowTask(_ item: WorktreePaletteItem) -> WorktreePaletteRowTask? {
    guard let key = item.worktreeKey,
      let task = tasks.tasks.first(where: { $0.worktree?.path == key })
    else { return nil }
    return WorktreePaletteRowTask(task: task, agent: task.agent(in: agents.agents))
  }

  /// 選んでいる行の ↵ がタスクに起こすこと。文脈が無い・↵ が worktree を用意しない行（clean・ベースを選ぶ
  /// 画面へ入る作成行）・何も変わらないときは nil。
  var taskEffect: WorktreePaletteTaskEffect? {
    guard let task, let item = selectedItem else { return nil }
    switch item.action {
    case .clean: return nil
    case .createBranch: if selectedBaseChoice?.base == nil { return nil }
    case .open: break
    }
    let previousOwner = item.worktreeKey.flatMap { key in
      tasks.tasks.first { $0.id != task.id && $0.worktree?.path == key }
    }
    let begins = task.status != .inProgress
    guard begins || previousOwner != nil else { return nil }
    return WorktreePaletteTaskEffect(task: task, begins: begins, previousOwner: previousOwner)
  }

  /// 別のリポジトリを読み直す前に、前のリポジトリから得た事実（行・分類・ベース）を捨てる。打った名前が
  /// ブランチ名として有効かの答えはリポジトリに依らないので残す。
  /// 新しい一覧が届くまではスケルトンを出し、前のリポジトリの行で ↵ が決まらないようにする。
  func discardRepositoryFacts() {
    hasLoadedOnce = false
    sections = []
    classification = nil
    classificationPending = false
    baseFacts = nil
    baseCandidates = []
    newBranchRules = nil
    pickedBase = nil
    selectedBaseRole = nil
    taskTargetPending = false
    errorMessage = nil
  }
}
