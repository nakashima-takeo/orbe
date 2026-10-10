import Foundation

/// `start_task` の要求。`branch`・`repo` はリポジトリのタスクでだけ読む。
struct TaskStartRequest {
  let taskId: Int
  var branch: String?
  var repo: String?
  var agent: String?
  var prompt: String?
}

/// `start_task` が拒んだ・失敗した理由。拒否（`-32602`）はタスクを変えない。
enum TaskStartFailure: Error, Equatable {
  case invalid(String)
  case failed(String)

  var controlError: ControlError {
    switch self {
    case .invalid(let message): ControlError(code: -32602, message: message)
    case .failed(let message): ControlError(code: -32000, message: message)
    }
  }
}

/// 用意できた作業場。
struct TaskWorkplace: Equatable {
  let path: String
  /// 作業場を新しく作った（worktree の作成・Home のフォルダの作成）。
  let created: Bool
  /// 使ったリポジトリ（本体 worktree）。Home のタスクには無い。
  var repo: String?
}

/// リポジトリのタスクの作業場（worktree）を、⌘T の「タスクから開く」と同じ規則で用意する（`start_task`）。
/// リポジトリの事実の層（`WorktreeRepoFacts`）を通り、行き先が決まるまで（fetch の着地・remote の正式名・主の PR の
/// head）待ってから 1 度だけ答える。決まるまでの間は自分を事実の層の知らせに繋いで生かし、答えたら切る。
///
/// リポジトリは人の画面の状態で決めない（⌘T は「その workspace でアクティブなタブ」のリポジトリを使うが、画面の無い
/// 呼び出しが人の操作次第で別のリポジトリに向く）。決める順はタスクの worktree → `repo` → workspace の root で、
/// git の中の最初のものを使う。
final class TaskRepoWorktree {
  private let task: TaskItem
  private let branch: String?
  private var candidates: [String]
  private let items: GitHubItemCache
  private let makeFacts: (String) -> WorktreeRepoFacts
  private var facts: WorktreeRepoFacts?
  private var completion: ((Result<TaskWorkplace, TaskStartFailure>) -> Void)?
  /// 行き先を決める段を過ぎた（用意に入った）。以後の知らせでは決め直さない。
  private var decided = false
  private var observingItems = false

  /// `candidates` はリポジトリを探す場所（順に試す）。`makeFacts` はその場所の事実の層を作る。
  init(
    task: TaskItem, branch: String?, candidates: [String], items: GitHubItemCache,
    makeFacts: @escaping (String) -> WorktreeRepoFacts
  ) {
    self.task = task
    self.branch = branch
    self.candidates = candidates
    self.items = items
    self.makeFacts = makeFacts
  }

  func start(completion: @escaping (Result<TaskWorkplace, TaskStartFailure>) -> Void) {
    self.completion = completion
    if let primary = task.links.first, primary.kind == .pr, branch == nil {
      items.ensure([primary.item])
    }
    openNextCandidate()
  }

  private func openNextCandidate() {
    guard !candidates.isEmpty else {
      return finish(.failure(.invalid("no git repository for this task; pass repo")))
    }
    let facts = makeFacts(candidates.removeFirst())
    self.facts = facts
    facts.onChange = { change in
      if case .outsideRepository = change { return self.openNextCandidate() }
      self.decide()
    }
    facts.load()
  }

  /// 事実が動くたびに行き先を決め直す。決まらなければ次の知らせ（と主の PR の head の答え）を待つ。
  private func decide() {
    guard !decided, let facts, facts.hasLandedGit, let decision = target(facts) else { return }
    let target: WorktreePaletteTaskTarget
    switch decision {
    case .failure(let failure): return finish(.failure(failure))
    case .success(let found): target = found
    }
    switch target {
    case .pending:
      return observeItems()
    case .none:
      return finish(.failure(.invalid("cannot decide the branch for this task; pass branch")))
    case .worktree, .branch:
      break
    }
    guard
      let plan = WorktreeRepoFacts.plan(
        for: target, worktrees: facts.worktrees, localBranches: facts.localBranches,
        remoteBranches: facts.remoteBranches, newBranchRules: facts.newBranchRules)
    else {
      return finish(
        .failure(
          .invalid(
            branch.map {
              "branch \($0) cannot be created here (name or worktree location conflicts)"
            }
              ?? "cannot decide the branch for this task; pass branch")))
    }
    if case .open(.directory(let path)) = plan,
      GitWorktreeRoot.normalizedPath(path) == GitWorktreeRoot.normalizedPath(facts.worktreeBase)
    {
      return finish(
        .failure(
          .invalid(
            "the main worktree \(path) cannot be a task's workplace; pass another branch")))
    }
    decided = true
    switch plan {
    case .open(let destination):
      prepare(destination, facts)
    case .create(let name):
      GitRepo.checkBranchName(name, cwd: facts.cwd, runner: facts.runner) { valid in
        guard valid else {
          return self.finish(.failure(.invalid("invalid branch name: \(name)")))
        }
        self.prepare(.newBranch(name: name, base: .defaultBranch), facts)
      }
    }
  }

  /// 行き先。タスク自身の worktree が今の一覧にあればそれで、remote は照合しない（照合は主の結び付きから新しく決める
  /// ときだけ）。無ければ主の結び付きのリポジトリを指す remote を確かめてから、`branch` か主の結び付きで決める。remote が
  /// まだ分からなければ nil。
  private func target(_ facts: WorktreeRepoFacts) -> Result<
    WorktreePaletteTaskTarget, TaskStartFailure
  >? {
    let own = facts.taskTarget(WorktreePaletteTaskInputs(task: task, items: items))
    if case .worktree = own { return .success(own) }
    let primary = task.links.first
    if let primary {
      switch facts.hasRemote(for: primary.item.repo) {
      case nil: return nil
      case false?:
        return .failure(
          .invalid(
            "repository mismatch: \(facts.worktreeBase) has no remote for \(primary.item.repo.value)"
          ))
      case true?: break
      }
    }
    return .success(
      branch.map { facts.taskTarget(branch: $0, primary: primary?.item.repo) } ?? own)
  }

  /// 主の PR の head の答えが届いたら決め直す（事実の層の知らせとは別の置き場から来る）。
  private func observeItems() {
    guard !observingItems else { return }
    observingItems = true
    withObservationTracking {
      _ = WorktreePaletteTaskInputs(task: task, items: items)
    } onChange: {
      DispatchQueue.main.async {
        self.observingItems = false
        self.decide()
      }
    }
  }

  /// 遅れたローカルブランチは、⌘T で人に問う最新化（fetch → fast-forward → 作成）をそのまま行う。
  private func prepare(_ destination: WorktreePaletteDestination, _ facts: WorktreeRepoFacts) {
    let repo = facts.worktreeBase
    let created = destination.existingDirectory == nil
    let ready = { (resolution: WorktreeRepoFacts.DirectoryResolution) in
      switch resolution {
      case .ready(let path):
        self.finish(.success(TaskWorkplace(path: path, created: created, repo: repo)))
      case .failed(let message):
        self.finish(.failure(.failed(message)))
      }
    }
    facts.prepareDirectory(for: destination) { outcome in
      switch outcome {
      case .resolved(let resolution):
        ready(resolution)
      case .created(let path, _):
        ready(.ready(path))
      case .staleBranch(let sync, _):
        facts.refreshAndCreate(
          sync, creating: {},
          completion: { result in
            switch result {
            case .success(let resolution): ready(resolution)
            case .failure(let failure):
              let reason = WorktreePaletteRefreshFailureText.reason(
                failure, upstream: sync.upstream, facts.localization)
              self.finish(
                .failure(
                  .failed(
                    "\(WorktreePaletteRefreshFailureText.step(failure)) of \(sync.name) failed: \(reason)"
                  )))
            }
          })
      }
    }
  }

  private func finish(_ result: Result<TaskWorkplace, TaskStartFailure>) {
    guard let completion else { return }
    self.completion = nil
    facts?.onChange = { _ in }
    completion(result)
  }
}

/// 作業を始める agent への最初の入力（Orbe が UI の言語で組む）。
enum TaskStartText {
  /// Home のタスク: タスク（ID・タイトル・詳細）と、あれば `prompt`。起動引数なので複数行でよい。
  static func homeFirstInput(_ task: TaskItem, prompt: String?, l10n: LocalizationStore) -> String {
    var lines = [l10n.format(.taskStartHomeTask, "\(task.id)", task.title)]
    let description = task.description.trimmingCharacters(in: .whitespacesAndNewlines)
    if !description.isEmpty { lines += [l10n.string(.taskStartHomeDescription), description] }
    if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
      lines += ["", prompt]
    }
    return lines.joined(separator: "\n")
  }
}
