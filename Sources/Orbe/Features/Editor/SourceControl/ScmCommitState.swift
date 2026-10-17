import Foundation

/// コミットボタンと ▾ の項目の姿（純関数）。コミットできる変更が 1 つも無いとき、ボタンは「同期 ↑N ↓M」（pull → push）か、
/// コミットがあり upstream の無いブランチでは「ブランチを公開」に替わる。HEAD が push 済みなら amend・取り消しは押せない
/// （force push を持たないので、書き換えたら Orbe の中では戻れない）。push 済みか分からない間と、ネット操作が走っている・
/// 順番を待っている間も押せない側に倒す（push と並んで走ると、push したコミットを書き換えうる）。
struct ScmCommitState: Equatable {
  enum Primary: Equatable {
    case commit
    case sync(GitStatus.Divergence)
    case publish
  }

  /// コミット・amend に入れる範囲。ステージ済みがあれば（`hasStaged`）それだけ、無ければ「変更」のコミットに入る行の
  /// 全部（確かめない）。
  enum Scope: Equatable {
    case staged
    case all
  }

  let primary: Primary
  let scope: Scope
  let isPrimaryEnabled: Bool
  /// コミットだけの入口（✓・⌘↵）が押せる。ボタンが同期・公開でもネット操作は起こさない。
  let canCommit: Bool
  let canAmend: Bool
  let canCommitAndPush: Bool
  let canUndo: Bool
  /// ▾ が開く（中の項目が 1 つでも押せる）。
  let isMenuEnabled: Bool
  /// プル・プッシュ・フェッチ（前提は根のサービスが判定する。同じ worktree のネット操作が走っている間だけ押せない）。
  let canNetwork: Bool

  /// `staged`・`changes`・`committable` は見えている行の数（`committable` はステージ済みが無いときにコミットへ入る行）。
  /// `hasStaged` は押せばコミットより先にステージ済みになっているものがあるか——根のサービスの今の status か、列にある
  /// ステージ（行の組み直しは status より遅れて当たるので、見えている行の数では決めない）。`isHeadPushed` は nil = 分からない。
  init(
    staged: Int, changes: Int, committable: Int, branch: GitStatus.Branch?,
    messageIsBlank: Bool, isNetworking: Bool, isCommitting: Bool, hasStaged: Bool,
    isHeadPushed: Bool?
  ) {
    scope = hasStaged ? .staged : .all
    canCommit = (staged > 0 || committable > 0) && !messageIsBlank && !isCommitting
    canNetwork = !isNetworking
    if staged + changes > 0 {
      primary = .commit
      isPrimaryEnabled = canCommit
    } else if let branch, branch.name != nil, let upstream = branch.upstream {
      if let divergence = upstream.divergence, divergence.ahead + divergence.behind > 0 {
        primary = .sync(divergence)
        isPrimaryEnabled = !isNetworking
      } else {
        primary = .commit
        isPrimaryEnabled = false
      }
    } else if let branch, branch.name != nil, branch.commit != nil {
      primary = .publish
      isPrimaryEnabled = !isNetworking
    } else {
      primary = .commit
      isPrimaryEnabled = false
    }
    let rewritable =
      branch?.commit != nil && isHeadPushed == false && !isCommitting && !isNetworking
    canAmend = rewritable && (staged > 0 || committable > 0 || !messageIsBlank)
    canUndo = rewritable
    canCommitAndPush = canCommit && !isNetworking
    isMenuEnabled = canAmend || canCommitAndPush || canUndo
  }
}
