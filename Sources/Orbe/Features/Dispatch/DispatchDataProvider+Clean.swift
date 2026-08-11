import Foundation

/// clean の削除の駆動。判断（何を消すか）は `DispatchCleanModel`、実行は `DispatchWorktreeCleaner` が
/// 持ち、ここは repo の解決と「終わったら唯一の真実を引き直す」ことだけを担う。
extension DispatchDataProvider {

  /// 選択された worktree を削除する（実行と 1 件ごとの報告は `DispatchWorktreeCleaner` が担う）。
  ///
  /// 完了の前に git レーンを引き直す。削除は worktree・ブランチ・分類の複数レーンを動かすので、
  /// 唯一の真実を削除前のままにしない——一覧へ戻った先で消えた worktree の行が残っていたり、
  /// clean へ入り直したときにそれが「安全」へチェック済みで復活したりしないため。
  func deleteWorktrees(
    _ requests: [CleanDeleteRequest], token: CleanRunToken,
    progress: @escaping (CleanProgress) -> Void, completion: @escaping () -> Void
  ) {
    guard let repo else {
      for request in requests {
        progress(
          .finished(
            path: request.path,
            outcome: .failed(
              CleanFailure(
                step: .worktree, log: localization.string(.dispatchErrNotGitRepo)))))
      }
      completion()
      return
    }
    DispatchWorktreeCleaner(
      repo: repo, localization: localization,
      prunablePaths: Set(worktrees.filter(\.isPrunable).map(\.path))
    ).run(requests, token: token, progress: progress) { [weak self] in
      self?.loadGit(repo)
      completion()
    }
  }
}
