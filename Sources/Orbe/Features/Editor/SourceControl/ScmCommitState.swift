import Foundation

/// コミットボタンと ▾ の項目の姿（純関数）。ボタンは主の働きと ▾ で 1 つの可否を持つ（主が押せなければ ▾ も開かない）。
/// コミットできる変更が 1 つも無いとき、ボタンは「同期 ↑N ↓M」（pull → push）か、コミットがあり upstream の無いブランチ
/// では「ブランチを公開」に替わる。HEAD が push 済みなら amend・取り消しは押せない（force push を持たないので、書き換えたら
/// Orbe の中では戻れない）。push 済みか分からない間と、ネット操作が走っている・順番を待っている間も押せない側に倒す（push と
/// 並んで走ると、push したコミットを書き換えうる）。
struct ScmCommitState: Equatable {
  enum Primary: Equatable {
    case commit
    case sync(GitStatus.Divergence)
    case publish
  }

  let primary: Primary
  /// ボタン（主の働きと ▾）が押せる。
  let isButtonEnabled: Bool
  /// コミットだけの入口（✓・欄の ↵）が押せる。ボタンが同期・公開でもネット操作は起こさない。
  let canCommit: Bool
  let canAmend: Bool
  let canCommitAndPush: Bool
  let canUndo: Bool
  /// プル・プッシュ・フェッチ（前提は根のサービスが判定する。同じ worktree のネット操作が走っている間だけ押せない）。
  let canNetwork: Bool

  /// `staged`・`changes`・`committable` は見えている行の数（`committable` はステージ済みが無いときにコミットへ入る行）。
  /// `isHeadPushed` は nil = 分からない。
  init(
    staged: Int, changes: Int, committable: Int, branch: GitStatus.Branch?,
    messageIsBlank: Bool, isNetworking: Bool, isCommitting: Bool, isHeadPushed: Bool?
  ) {
    canCommit = (staged > 0 || committable > 0) && !messageIsBlank && !isCommitting
    canNetwork = !isNetworking
    if staged + changes > 0 {
      primary = .commit
      isButtonEnabled = canCommit
    } else if let branch, branch.name != nil, let upstream = branch.upstream {
      if let divergence = upstream.divergence, divergence.ahead + divergence.behind > 0 {
        primary = .sync(divergence)
        isButtonEnabled = !isNetworking
      } else {
        primary = .commit
        isButtonEnabled = false
      }
    } else if let branch, branch.name != nil, branch.commit != nil {
      primary = .publish
      isButtonEnabled = !isNetworking
    } else {
      primary = .commit
      isButtonEnabled = false
    }
    let rewritable =
      branch?.commit != nil && isHeadPushed == false && !isCommitting && !isNetworking
    canAmend = rewritable && (staged > 0 || committable > 0 || !messageIsBlank)
    canUndo = rewritable
    canCommitAndPush = canCommit && !isNetworking
  }
}
