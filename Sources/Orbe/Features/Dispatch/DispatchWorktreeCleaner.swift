import Foundation

/// 一括削除の結果。
struct CleanDeleteResult {
  /// worktree の削除に成功したパス（凍結スナップショットから取り除く対象）。
  let succeededPaths: [String]
  /// 1 件でも失敗したときの集約メッセージ。全件成功なら nil。
  let failureMessage: String?
}

/// 依頼された worktree（と、依頼が求めればローカルブランチ）を 1 件ずつ直列に削除する実行体。
/// **判断は持たない**——何を消すか・ブランチも消すかは `DispatchCleanModel` が決め、ここは実行と
/// 結果の集約だけを担う。値型なので、非同期の連鎖に閉じ込められたまま完了まで生き延びる。
struct DispatchWorktreeCleaner {
  let repo: GitRepo
  /// 失敗理由を現在言語で出すためのストア。
  let localization: LocalizationStore
  /// 実体が無い worktree のパス（削除直前の status 再確認を省く対象）。
  let prunablePaths: Set<String>

  /// **途中で失敗しても中断せず全件試み、結果を集約する**——削除は取り消せないので中断しても部分実行済みの
  /// 状態は残り、ユーザーが頼んだ残りを止める理由がない。
  /// 削除の直前に status をもう一度叩くのは、分類時の値が最大で数十秒前のものだから
  /// （`git worktree remove --force` の前提「作業ツリーが clean」を Orbe が自分で確かめる）。
  /// ブランチ側の凍結は `repo.deleteBranch` が `expectedOid` の compare-and-delete で受け持つ。
  /// git を触る順は `worktree remove` → ブランチ削除（逆順では checkout 済みのブランチを消せない）。
  func run(
    _ requests: [CleanDeleteRequest], completion: @escaping (CleanDeleteResult) -> Void
  ) {
    var succeeded: [String] = []
    var failures: [String] = []

    func finish() {
      completion(
        CleanDeleteResult(
          succeededPaths: succeeded,
          failureMessage: failures.isEmpty
            ? nil
            : localization.format(
              .dispatchCleanFailure, requests.count, failures.count,
              failures.joined(separator: " / "))))
    }

    func step(_ index: Int) {
      guard index < requests.count else {
        finish()
        return
      }
      let request = requests[index]
      let name = (request.path as NSString).lastPathComponent
      let remove = {
        repo.removeWorktree(path: request.path) { error in
          if let error {
            failures.append("\(name): \(error)")
            step(index + 1)
            return
          }
          succeeded.append(request.path)
          guard let branch = request.branch, request.deleteBranch else {
            step(index + 1)
            return
          }
          repo.deleteBranch(name: branch, expectedOid: request.head) { branchError in
            if let branchError { failures.append("\(name): \(branchError)") }
            step(index + 1)
          }
        }
      }
      guard !prunablePaths.contains(request.path) else {
        remove()
        return
      }
      repo.worktreeIsClean(at: request.path) { isClean in
        guard isClean else {
          failures.append("\(name): \(localization.string(.dispatchCleanDirty))")
          step(index + 1)
          return
        }
        remove()
      }
    }
    step(0)
  }
}
