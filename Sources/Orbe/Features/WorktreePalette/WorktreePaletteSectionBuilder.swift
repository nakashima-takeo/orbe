import Foundation

/// parsed な git モデルから `[WorktreePaletteSection]` を組み立てる純粋関数（subprocess 非依存）。
/// 重複排除・空セクション除外をここに集約し、mock 入力で決定的にテストする。実データ取得は
/// `WorktreePaletteDataProvider` が担う。
enum WorktreePaletteSectionBuilder {
  /// 組み立ての入力（parsed モデル一式）。
  struct Input {
    var worktrees: [GitWorktree] = []
    var localBranches: [GitBranch] = []
    var remoteBranches: [GitBranch] = []
    /// 現在のチェックアウト（repo.root）。一致する worktree を primary（強調）にする。
    var currentWorktree: String?
    /// clean 行の候補件数（safe 群の件数）。nil は分類レーンが未着地＝バッジを出さない。
    var cleanCandidates: Int?
    /// 提示時の `fetch --prune` が着地した（列挙が fetch 後の値）。Local branch 行の同期ピルは
    /// 着地後の値だけを出す——fetch 前の差は古い remote 追跡 ref との差で、事実として嘘になる。
    var remoteFetchLanded = false
  }

  static func build(_ input: Input) -> [WorktreePaletteSection] {
    var sections: [WorktreePaletteSection] = []
    append(&sections, title: "Worktrees", items: worktreeItems(input))
    append(&sections, title: "Local branches", items: localBranchItems(input))
    append(&sections, title: "Remote branches", items: remoteBranchItems(input))
    return sections
  }

  // MARK: - セクションごとの item 組み立て

  /// Worktrees（main 含む全チェックアウト）。現在のチェックアウトは primary で強調する。
  /// 末尾に clean 画面への入口を 1 行置く（**候補 0 件でも行は残り、バッジだけ消える**）。
  private static func worktreeItems(_ input: Input) -> [WorktreePaletteItem] {
    guard !input.worktrees.isEmpty else { return [] }
    return input.worktrees.map { worktree in
      let name = (worktree.path as NSString).lastPathComponent
      var detail = abbreviate(worktree.path)
      if let branch = worktree.branch { detail += " · \(branch)" }
      let isPrimary = input.currentWorktree == worktree.path
      return WorktreePaletteItem(
        glyph: .worktree, name: name, detail: detail,
        showsWorkingIndicator: isPrimary, isPrimary: isPrimary,
        action: .open(.worktree(path: worktree.path)),
        footer: .launch(target: name, kind: .existing))
    } + [cleanItem(input)]
  }

  /// Worktrees セクション末尾の `clean` 行。`clean` は技術語で日英同一（`shell` と同じ扱い）。
  private static func cleanItem(_ input: Input) -> WorktreePaletteItem {
    WorktreePaletteItem(
      glyph: .clean, name: "clean", detailKey: .worktreeCleanSubtitle,
      aliases: ["rm", "prune", "掃除"], candidateCount: input.cleanCandidates,
      action: .clean, footer: .note(.worktreeCleanListNote))
  }

  /// Local branches（worktree で checkout 中のものは Worktrees に出るので重複排除）。
  private static func localBranchItems(_ input: Input) -> [WorktreePaletteItem] {
    let checkedOut = Set(input.worktrees.compactMap(\.branch))
    return input.localBranches
      .filter { !checkedOut.contains($0.name) }
      .map { branch in
        WorktreePaletteItem(
          glyph: .localBranch, name: branch.name, detail: branch.relativeDate,
          sync: input.remoteFetchLanded ? WorktreePaletteBranchSync(branch) : nil,
          action: .open(.localBranch(name: branch.name)),
          footer: .launch(target: branch.name, kind: .checkout))
      }
  }

  /// Remote branches（ローカル追跡済みは出さない・既存 worktree は action に焼き込む）。
  private static func remoteBranchItems(_ input: Input) -> [WorktreePaletteItem] {
    let localNames = Set(input.localBranches.map(\.name))
    return input.remoteBranches.compactMap { branch in
      let local = localName(fromRemote: branch.name)
      guard !localNames.contains(local) else { return nil }
      return WorktreePaletteItem(
        glyph: .remoteBranch, name: branch.name, detail: branch.relativeDate,
        action: .open(
          .remoteBranch(
            name: branch.name, existingWorktree: input.worktrees.first { $0.branch == local }?.path)
        ),
        footer: .launch(target: branch.name, kind: .checkout))
    }
  }

  // MARK: - 補助

  private static func append(
    _ sections: inout [WorktreePaletteSection], title: String, items: [WorktreePaletteItem]
  ) {
    guard !items.isEmpty else { return }
    sections.append(WorktreePaletteSection(title: title, items: items))
  }

  /// `origin/feat/x` → `feat/x`（先頭のリモート名を落とす）。
  private static func localName(fromRemote name: String) -> String {
    let parts = name.split(separator: "/", maxSplits: 1)
    return parts.count == 2 ? String(parts[1]) : name
  }

  private static func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}

#if DEBUG
  extension WorktreePaletteSectionBuilder.Input {
    /// worktree パレットの代表シーンに対応する決定的サンプル（preview / gallery / 視覚突合用）。
    /// 実データ形。live git は叩かない。
    static var designSample: WorktreePaletteSectionBuilder.Input {
      let home = NSHomeDirectory()
      return WorktreePaletteSectionBuilder.Input(
        worktrees: [
          GitWorktree(
            path: "\(home)/wt/agent-hooks", branch: "feature/agent-hooks", head: "a1", isMain: false
          ),
          GitWorktree(
            path: "\(home)/wt/diff-panel", branch: "fix/diff-panel", head: "b2", isMain: false),
        ],
        localBranches: [
          GitBranch(
            name: "main", relativeDate: "1d ago",
            upstream: upstream("main", ahead: 0, behind: 12)),
          GitBranch(
            name: "perf/render-batching", relativeDate: "5d ago",
            upstream: upstream("perf/render-batching", ahead: 2, behind: 5)),
        ],
        remoteBranches: [
          GitBranch(
            name: "origin/feat/session-restore", relativeDate: "taro · 3h ago", upstream: nil)
        ],
        currentWorktree: "\(home)/wt/agent-hooks",
        // clean 行の候補バッジ（design 正典の clean シーンの safe 群と同数）。
        cleanCandidates: 3,
        // Local branch 行の同期ピル（`↓12` / `↑2 ↓5`）は着地後の値だけ出る。
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
