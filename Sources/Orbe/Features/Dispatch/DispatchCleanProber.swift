import Foundation

/// 分類レーンのプローブ。各 worktree の「作業ツリーが clean か」「既定ブランチに取り込み済みか」を
/// 実測して集める。**判定はしない**——群への振り分けは `DispatchWorktreeClassifier` が純粋に行う。
///
/// ペイン占有・main worktree で inUse と判った行はプローブを省く（消せないと分かっている行に
/// プロセスを割かない）。実体が無い（prunable）行は status を問わない——失うものが無いので
/// 「作業ツリーが clean」は自動的に満たす。
struct DispatchCleanProber {
  let repo: GitRepo
  let defaultBranch: String

  /// 実測を集めて path → 実測の辞書で返す。completion はメインで返る（`GitRunner` 契約）。
  func probe(
    worktrees: [GitWorktree], panes: [PaneOccupancy],
    completion: @escaping ([String: DispatchCleanProbe]) -> Void
  ) {
    let occupancy = DispatchWorktreeClassifier.occupancies(
      worktreePaths: worktrees.map(\.path), panes: panes)
    var probes: [String: DispatchCleanProbe] = [:]
    let group = DispatchGroup()
    for worktree in worktrees where !worktree.isMain && occupancy[worktree.path] == nil {
      probes[worktree.path] = DispatchCleanProbe()
      if !worktree.isPrunable {
        group.enter()
        repo.worktreeIsClean(at: worktree.path) { isClean in
          probes[worktree.path]?.isDirty = !isClean
          group.leave()
        }
      }
      group.enter()
      repo.unmergedCommitCount(
        branchOrCommit: worktree.branch ?? worktree.head, default: defaultBranch
      ) { count in
        probes[worktree.path]?.unmergedCommits = count
        group.leave()
      }
    }
    group.notify(queue: .main) { completion(probes) }
  }
}
