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
  /// 削除の直前に status と停止中の git 操作をもう一度確かめるのは、分類時の値が最大で数十秒前のもの
  /// だから。**確かめる述語は `DispatchWorktreeClassifier.passesSafety` の作業ツリー側と同じ 2 つ**——
  /// 「初期チェックに入る条件」と「撃つ直前に確かめる条件」を食い違わせない
  /// （status が空でも rebase 途中の worktree は消さない）。
  /// ブランチ側は「確定した時点の先端であるときだけ消す」を `repo.deleteBranch` の `expectedOid`
  /// compare-and-delete が受け持つ。
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
      progress(.started(path: request.path))
      delete(request) { outcome in
        progress(.finished(path: request.path, outcome: outcome))
        step(index + 1)
      }
    }
    step(0)
  }

  /// 1 件を撃つ。関門 → `worktree remove` → ブランチ削除の順で、途中で落ちたらそこで結果を返す。
  private func delete(_ request: CleanDeleteRequest, finish: @escaping (CleanOutcome) -> Void) {
    let pruned = prunablePaths.contains(request.path)
    func fail(_ failureStep: CleanFailureStep, _ failure: GitWorktreeCleanFailure) {
      // 打ち切りでは stderr が空になりうる。サブラインが空欄で開かないよう文言を代わりに載せる。
      let log =
        failure.timedOut && failure.log.isEmpty ? localization.string(.gitTimedOut) : failure.log
      finish(.failed(CleanFailure(step: failureStep, log: log)))
    }
    let deleteBranch = {
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
    let remove = {
      repo.removeWorktree(path: request.path) { failure in
        if let failure {
          fail(.worktree, failure)
          return
        }
        deleteBranch()
      }
    }
    // 前の試行で worktree が消えた行の再試行は、残りのブランチ削除だけを撃つ。実体の無いパスへ
    // status を撃てば必ず失敗し、「未コミットの変更がある」という事実と逆の理由が出る。
    guard !request.worktreeAlreadyRemoved else {
      deleteBranch()
      return
    }
    guard !pruned else {
      remove()
      return
    }
    // 関門で止めた行は git を撃っていないので生ログを持たない（行の理由だけが残る）。
    repo.worktreeIsClean(at: request.path) { isClean in
      guard isClean else {
        finish(.failed(CleanFailure(step: .dirty, log: "")))
        return
      }
      guard GitWorktreeOperationProbe.detect(worktreeAt: request.path) == .none else {
        finish(.failed(CleanFailure(step: .operationInProgress, log: "")))
        return
      }
      remove()
    }
  }
}
