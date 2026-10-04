import Foundation

/// 先頭の「#221 の worktree」の欄を決めるのに要る、⌘T の外（タスクのストア・GitHub の値の置き場）の値の写し。
/// モデルが描くたびにストアと置き場から導き、カードがその変化を見て provider に組み直させる（provider に
/// 届く経路はこの 1 本）。
struct WorktreePaletteTaskInputs: Equatable {
  /// 主の PR の head（ブランチ名を GitHub から取る）。
  enum PullRequestHead: Equatable {
    /// 主が PR でない。
    case none
    /// まだ取れていない（試していないか、取得中）。
    case pending
    /// 取れなかった・head のリポジトリが消えている。
    case unavailable
    case found(GitHubBranchRef)
  }

  /// 文脈のタスク。文脈が無い・タスクが消えたなら nil。
  let taskID: Int?
  let worktree: TaskWorktree?
  let primary: TaskLink?
  let pullRequestHead: PullRequestHead

  static let none = WorktreePaletteTaskInputs(
    taskID: nil, worktree: nil, primary: nil, pullRequestHead: .none)

  init(
    taskID: Int?, worktree: TaskWorktree?, primary: TaskLink?, pullRequestHead: PullRequestHead
  ) {
    self.taskID = taskID
    self.worktree = worktree
    self.primary = primary
    self.pullRequestHead = pullRequestHead
  }

  /// タスクと置き場から導く。
  init(task: TaskItem?, items: GitHubItemCache) {
    guard let task else {
      self = .none
      return
    }
    let primary = task.links.first
    var head = PullRequestHead.none
    if let primary, primary.kind == .pr {
      switch items.answers[primary.item] {
      case .found(let summary):
        head = summary.pullRequest?.head.map(PullRequestHead.found) ?? .unavailable
      case .missing:
        head = .unavailable
      case nil:
        head = items.isAwaitingAnswer(primary.item) ? .pending : .unavailable
      }
    }
    self.init(taskID: task.id, worktree: task.worktree, primary: primary, pullRequestHead: head)
  }
}

/// 先頭の欄の解決の結果。provider が rebuild のたびに、文脈の入力と git・remote の台帳の事実から導く。
enum WorktreePaletteTaskTarget: Equatable {
  /// 欄を出さない（文脈が無い・手元のリポジトリから扱えない Issue・PR・主が無い）。
  case none
  /// まだ決まらない（PR のブランチ名を取っている・remote の正式名を待っている）。↵ は預かる。
  case pending
  /// タスクの worktree（今の一覧にある worktree のパス）。
  case worktree(path: String)
  /// ブランチ（Issue なら `issue/<N>`、PR ならその head）。`remotes` はそのリポジトリを指す手元の remote。
  case branch(name: String, pullRequest: Int?, remotes: [String])
}
