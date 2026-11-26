import Foundation

/// コミットのポップアップの「コミット」と ▾ の項目、左の列の見出しの … の項目の可否（純関数）。HEAD が push 済みなら amend・
/// 取り消しは押せない（force push を持たないので、書き換えたら Orbe の中では戻れない）。push 済みか分からない間と、ネット操作が
/// 走っている・順番を待っている間も押せない側に倒す（push と並んで走ると、push したコミットを書き換えうる）。
struct ScmCommitState: Equatable {
  /// コミットだけの入口（「コミット」・欄の ↵）が押せる。
  let canCommit: Bool
  let canAmend: Bool
  let canCommitAndPush: Bool
  let canUndo: Bool
  /// プル・プッシュ・フェッチ（前提は根のサービスが判定する。同じ worktree のネット操作が走っている間だけ押せない）。
  let canNetwork: Bool

  /// `staged`・`committable` は見えている行の数（`committable` はステージ済みが無いときにコミットへ入る行）。
  /// `isHeadPushed` は nil = 分からない。
  init(
    staged: Int, committable: Int, branch: GitStatus.Branch?, messageIsBlank: Bool,
    isNetworking: Bool, isCommitting: Bool, isHeadPushed: Bool?
  ) {
    canCommit = (staged > 0 || committable > 0) && !messageIsBlank && !isCommitting
    canNetwork = !isNetworking
    let rewritable =
      branch?.commit != nil && isHeadPushed == false && !isCommitting && !isNetworking
    canAmend = rewritable && (staged > 0 || committable > 0 || !messageIsBlank)
    canUndo = rewritable
    canCommitAndPush = canCommit && !isNetworking
  }
}
