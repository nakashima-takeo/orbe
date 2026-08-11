import Foundation

/// 削除 1 件の結果。**per-row の失敗を型で持つ**（1 本の文字列へ集約すると、どの行がなぜ落ちたかを
/// 画面が描けない）。
enum CleanOutcome: Equatable {
  /// 削除できた。`branch` はブランチも消したときだけ名前を持ち、`pruned` は実体の無い登録の掃除。
  case succeeded(branch: String?, pruned: Bool)
  case failed(CleanFailure)
}

/// 削除の進捗。**対象はパスで名乗る**——再試行では失敗行だけを撃ち直すので、実行器の数える index は
/// 受け手の行の並びと一致しない。
enum CleanProgress: Equatable {
  case started(path: String)
  case finished(path: String, outcome: CleanOutcome)
}

/// 依頼された worktree（と、依頼が求めればローカルブランチ）を 1 件ずつ直列に削除する実行体。
/// **判断は持たない**——何を消すか・ブランチも消すかは `DispatchCleanModel` が決め、ここは実行と
/// 1 件ごとの結果の報告だけを担う。値型なので、非同期の連鎖に閉じ込められたまま完了まで生き延びる。
struct DispatchWorktreeCleaner {
  let repo: GitRepo
  /// 打ち切り（stderr が空になる）の文言を現在言語で出すためのストア。
  let localization: LocalizationStore
  /// 実体が無い worktree のパス（削除直前の status 再確認を省く対象）。
  let prunablePaths: Set<String>

  /// 1 件ずつ撃ち、**各件の頭で中断の札を見る**。撃った 1 件は完走させる（途中で殺すと管理ディレクトリが
  /// 半端に残る）ので、中断が止めるのはまだ撃っていない残りだけ。
  ///
  /// 削除の直前に status をもう一度叩くのは、分類時の値が最大で数十秒前のものだから
  /// （`git worktree remove --force` の前提「作業ツリーが clean」を Orbe が自分で確かめる）。
  /// ブランチ側の凍結は `repo.deleteBranch` が `expectedOid` の compare-and-delete で受け持つ。
  /// git を触る順は `worktree remove` → ブランチ削除（逆順では checkout 済みのブランチを消せない）。
  func run(
    _ requests: [CleanDeleteRequest], token: CleanRunToken,
    progress: @escaping (CleanProgress) -> Void, completion: @escaping () -> Void
  ) {
    func step(_ index: Int) {
      guard index < requests.count, !token.isCancelled else {
        completion()
        return
      }
      let request = requests[index]
      let pruned = prunablePaths.contains(request.path)
      progress(.started(path: request.path))

      func finish(_ outcome: CleanOutcome) {
        progress(.finished(path: request.path, outcome: outcome))
        step(index + 1)
      }
      func fail(_ step: CleanFailureStep, _ failure: GitWorktreeCleanFailure) {
        // 打ち切りでは stderr が空になりうる。サブラインが空欄で開かないよう文言を代わりに載せる。
        let log =
          failure.timedOut && failure.log.isEmpty
          ? localization.string(.gitTimedOut) : failure.log
        finish(.failed(CleanFailure(step: step, log: log)))
      }
      let remove = {
        repo.removeWorktree(path: request.path) { failure in
          if let failure {
            fail(.worktree, failure)
            return
          }
          guard let branch = request.branch, request.deleteBranch else {
            finish(.succeeded(branch: nil, pruned: pruned))
            return
          }
          repo.deleteBranch(name: branch, expectedOid: request.head) { branchFailure in
            if let branchFailure {
              fail(.branch, branchFailure)
              return
            }
            finish(.succeeded(branch: branch, pruned: pruned))
          }
        }
      }
      guard !pruned else {
        remove()
        return
      }
      repo.worktreeIsClean(at: request.path) { isClean in
        guard isClean else {
          // 撃つ前に止めたので git の生ログが無い（行の理由だけが残る）。
          finish(.failed(CleanFailure(step: .dirty, log: "")))
          return
        }
        remove()
      }
    }
    step(0)
  }
}
