import Foundation

/// parsed な git モデルから `[WorktreePaletteSection]` を組み立てる純粋関数（subprocess 非依存）。
/// 重複排除・空セクション除外をここに集約し、mock 入力で決定的にテストする。実データ取得は
/// `WorktreePaletteDataProvider` が担う。作成行は入力に応じてモデルが足す（`newBranchItem`）。
enum WorktreePaletteSectionBuilder {
  /// 組み立ての入力（parsed モデル一式）。
  struct Input {
    var worktrees: [GitWorktree] = []
    var localBranches: [GitBranch] = []
    var remoteBranches: [GitBranch] = []
    /// worktree の欄の見出しに添えるリポジトリ名（本体 worktree の basename）。
    var repositoryName = ""
    /// 今の worktree のパス（`worktrees` の中の値そのもの）。一致する worktree に「現在」の札を付ける。
    var currentWorktree: String?
    /// clean 行の候補件数（safe 群の件数）。nil は分類レーンが未着地＝バッジを出さない。
    var cleanCandidates: Int?
    /// 提示時の `fetch --prune` が着地した（列挙が fetch 後の値）。Local branch 行の同期ピルは
    /// 着地後の値だけを出す——fetch 前の差は古い remote 追跡 ref との差で、事実として嘘になる。
    var remoteFetchLanded = false
    /// タスクから開いたときの先頭の欄の行き先（provider が導く）。
    var taskTarget = WorktreePaletteTaskTarget.none
    /// 先頭の欄の見出しに添える主の番号（無ければ「このタスクの worktree」）。
    var taskNumber: Int?
    /// 作成行の名前と作成先の衝突の規則。先頭の欄の作成行（`issue/<N>`）を出すかに使う。
    var newBranchRules: WorktreeNewBranchRules?
  }

  /// 先頭のタスクの欄（あれば）、worktree の欄（末尾に clean）、ブランチの欄（ローカルの後にリモート）。
  /// タスクの欄に出した行は、下の欄から外す（同じ行を 2 度出さない）。
  static func build(_ input: Input) -> [WorktreePaletteSection] {
    let worktrees = worktreeItems(input)
    let branches = localBranchItems(input) + remoteBranchItems(input)
    let taskItem = taskItem(input, among: worktrees + branches)
    let rest = { (items: [WorktreePaletteItem]) in
      items.filter { $0.action != taskItem?.action }
    }
    return [
      WorktreePaletteSection(
        title: .task(number: input.taskNumber), items: taskItem.map { [$0] } ?? []),
      WorktreePaletteSection(
        title: .worktrees(repository: input.repositoryName), items: rest(worktrees)),
      WorktreePaletteSection(title: .branches, items: rest(branches)),
    ].filter { !$0.items.isEmpty }
  }

  /// 先頭の欄の行。worktree → ローカルブランチ → そのリポジトリの remote のブランチの順に、今の一覧の行を
  /// 探す。どれも無く、作れる Issue のブランチなら作成行。見つからず作りもしないなら nil（欄を出さない）。
  private static func taskItem(_ input: Input, among items: [WorktreePaletteItem])
    -> WorktreePaletteItem?
  {
    let find = { (action: WorktreePaletteAction) in items.first { $0.action == action } }
    switch input.taskTarget {
    case .none, .pending:
      return nil
    case .worktree(let path):
      return find(.open(.directory(path: path)))
    case .branch(let name, let pullRequest, let remotes):
      if let worktree = input.worktrees.first(where: { $0.branch == name }) {
        return find(.open(.directory(path: worktree.path)))
      }
      let branch =
        find(.open(.localBranch(name: name)))
        ?? remotes.lazy.compactMap {
          remoteBranch(named: "\($0)/\(name)", in: items)
        }.first
      if var branch {
        if let pullRequest {
          branch.glyph = .pullRequest
          branch.pullRequest = pullRequest
        }
        return branch
      }
      guard pullRequest == nil, input.newBranchRules?.allows(name) == true else { return nil }
      return newBranchItem(name: name)
    }
  }

  /// 非 git の場所で開いたときの一覧（「このディレクトリ」の 1 行だけ）。⌘T ↵ の意味（今いる場所で
  /// 既定の agent を開く）を git の有無で変えないため、行を持たない画面にはしない。
  static func directorySections(path: String) -> [WorktreePaletteSection] {
    [
      WorktreePaletteSection(
        title: nil,
        items: [
          WorktreePaletteItem(
            glyph: .directory, name: "", nameKey: .worktreePaletteThisDirectory,
            detail: abbreviate(path), isCurrent: true,
            action: .open(.directory(path: path)),
            enter: .openDirectory(abbreviate(path)))
        ])
    ]
  }

  /// 打った名前の作成行（「＋ X を作る」）。
  static func newBranchItem(name: String) -> WorktreePaletteItem {
    WorktreePaletteItem(
      glyph: .newBranch, name: name, action: .createBranch(name: name), enter: .create(name))
  }

  /// リモートブランチの行は名前で探す（行き先に焼き込んだ既存の worktree の有無に依らない）。
  private static func remoteBranch(named name: String, in items: [WorktreePaletteItem])
    -> WorktreePaletteItem?
  {
    items.first {
      if case .open(.remoteBranch(name, _)) = $0.action { return true }
      return false
    }
  }

  // MARK: - セクションごとの item 組み立て

  /// worktree（main 含む全チェックアウト）。今のチェックアウトに「現在」の札を付ける。
  /// 末尾に clean 画面への入口を 1 行置く（**候補 0 件でも行は残り、バッジだけ消える**）。
  /// ブランチ名は出さず、絞り込みの別名にだけ効かせる（ブランチ名で引いた worktree が見つかる）。
  private static func worktreeItems(_ input: Input) -> [WorktreePaletteItem] {
    guard !input.worktrees.isEmpty else { return [] }
    return input.worktrees.map { worktree in
      let name = (worktree.path as NSString).lastPathComponent
      return WorktreePaletteItem(
        glyph: .worktree, name: name, detail: abbreviate(worktree.path),
        aliases: worktree.branch.map { [$0] } ?? [],
        isCurrent: input.currentWorktree == worktree.path,
        action: .open(.directory(path: worktree.path)), enter: .openWorktree(name))
    } + [cleanItem(input)]
  }

  /// worktree の欄の末尾の `clean` 行。`clean` は技術語で日英同一（`shell` と同じ扱い）。
  private static func cleanItem(_ input: Input) -> WorktreePaletteItem {
    WorktreePaletteItem(
      glyph: .clean, name: "clean", detailKey: .worktreeCleanSubtitle,
      aliases: ["rm", "prune", "掃除"], candidateCount: input.cleanCandidates,
      action: .clean, enter: .clean)
  }

  /// ローカルブランチ（worktree で checkout 中のものは worktree の欄に出るので重複排除）。
  private static func localBranchItems(_ input: Input) -> [WorktreePaletteItem] {
    let checkedOut = Set(input.worktrees.compactMap(\.branch))
    return input.localBranches
      .filter { !checkedOut.contains($0.name) }
      .map { branch in
        WorktreePaletteItem(
          glyph: .localBranch, name: branch.name, detail: branch.relativeDate,
          sync: input.remoteFetchLanded ? WorktreePaletteBranchSync(branch) : nil,
          action: .open(.localBranch(name: branch.name)), enter: .checkout(branch.name))
      }
  }

  /// リモートブランチ（ローカル追跡済みは出さない・既存 worktree は action に焼き込む）。
  private static func remoteBranchItems(_ input: Input) -> [WorktreePaletteItem] {
    let localNames = Set(input.localBranches.map(\.name))
    return input.remoteBranches.compactMap { branch in
      let local = GitBranch.localName(fromRemote: branch.name)
      guard !localNames.contains(local) else { return nil }
      return WorktreePaletteItem(
        glyph: .remoteBranch, name: branch.name, detail: branch.relativeDate,
        action: .open(
          .remoteBranch(
            name: branch.name, existingWorktree: input.worktrees.first { $0.branch == local }?.path)
        ),
        enter: .trackRemote(remote: branch.name, local: local))
    }
  }

  // MARK: - 補助

  private static func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}

#if DEBUG
  extension WorktreePaletteSectionBuilder.Input {
    /// worktree パレットの代表シーン（design 正典 XTWorktree）に対応する決定的サンプル
    /// （preview / gallery / 視覚突合用）。実データ形。live git は叩かない。
    static var designSample: WorktreePaletteSectionBuilder.Input {
      let home = NSHomeDirectory()
      return WorktreePaletteSectionBuilder.Input(
        worktrees: [
          GitWorktree(path: "\(home)/wt/issue-212", branch: "issue/212", head: "a1", isMain: false),
          GitWorktree(path: "\(home)/wt/pr-214", branch: "pr-214", head: "b2", isMain: false),
          GitWorktree(
            path: "\(home)/wt/perf-render-batching", branch: "perf/render-batching", head: "c3",
            isMain: false),
        ],
        localBranches: [
          GitBranch(name: "issue/212", relativeDate: "1d ago", upstream: nil),
          GitBranch(name: "pr-214", relativeDate: "2d ago", upstream: nil),
          GitBranch(name: "perf/render-batching", relativeDate: "2d ago", upstream: nil),
          GitBranch(name: "fix/login-blank", relativeDate: "3d ago", upstream: nil),
        ],
        remoteBranches: [
          GitBranch(
            name: "origin/feat/fetch-progress", relativeDate: "taro · 1d ago", upstream: nil)
        ],
        repositoryName: "orbe",
        currentWorktree: "\(home)/wt/issue-212",
        // clean 行の候補バッジ（design 正典 XTWorktree の「候補 2 件」）。
        cleanCandidates: 2,
        remoteFetchLanded: true)
    }

    /// origin を追跡する upstream（design 正典の `sync` に対応）。
    static func upstream(_ name: String, ahead: Int, behind: Int) -> GitUpstream {
      GitUpstream(
        short: "origin/\(name)", ref: "refs/remotes/origin/\(name)", remote: "origin",
        remoteRef: "refs/heads/\(name)", track: .counts(ahead: ahead, behind: behind))
    }
  }
#endif
