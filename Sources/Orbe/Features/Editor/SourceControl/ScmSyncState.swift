import Foundation

/// 同期のボタンの姿（純関数）。ブランチに居て upstream が在れば同期、コミットが在り upstream が無いブランチでは公開。
/// upstream の ref が手元に無い（リモートのブランチが消された）ブランチでは、同期の姿のまま押せない——プルは必ず断られ、
/// 公開に替えるとマージ後のブランチをリモートに作り直すため。detached HEAD・初回コミットの前・ブランチが分からない間は
/// 出さない（nil）。ネット操作が操作の列に在る間は押せない。
struct ScmSyncState: Equatable {
  enum Action: Equatable {
    /// 同期（プル → プッシュ）。数は、先行・遅れが分かり、その和が 1 以上のときだけ持つ。
    case sync(GitStatus.Divergence?)
    /// 同期の姿で押せない（upstream の ref が手元に無い）。持つのは upstream の名前（`origin/feat`）。
    case upstreamGone(String)
    /// upstream を付けるプッシュ（ブランチを公開）。
    case publish
  }

  let action: Action
  let isEnabled: Bool

  init?(branch: GitStatus.Branch?, isNetworking: Bool) {
    guard let branch, branch.name != nil else { return nil }
    if let upstream = branch.upstream {
      if let divergence = upstream.divergence {
        action = .sync(divergence.ahead + divergence.behind > 0 ? divergence : nil)
      } else {
        action = .upstreamGone(upstream.name)
      }
    } else if branch.commit != nil {
      action = .publish
    } else {
      return nil
    }
    if case .upstreamGone = action {
      isEnabled = false
    } else {
      isEnabled = !isNetworking
    }
  }
}
