import Foundation

/// 同期のボタンの姿（純関数）。ブランチに居て upstream が在れば同期、コミットが在り upstream が無いブランチでは公開。
/// detached HEAD・初回コミットの前・ブランチが分からない間は出さない（nil）。ネット操作が操作の列に在る間は押せない。
struct ScmSyncState: Equatable {
  enum Action: Equatable {
    /// 同期（プル → プッシュ）。数は、先行・遅れが分かり、その和が 1 以上のときだけ持つ。
    case sync(GitStatus.Divergence?)
    /// upstream を付けるプッシュ（ブランチを公開）。
    case publish
  }

  let action: Action
  let isEnabled: Bool

  init?(branch: GitStatus.Branch?, isNetworking: Bool) {
    guard let branch, branch.name != nil else { return nil }
    if let upstream = branch.upstream {
      action = .sync(upstream.divergence.flatMap { $0.ahead + $0.behind > 0 ? $0 : nil })
    } else if branch.commit != nil {
      action = .publish
    } else {
      return nil
    }
    isEnabled = !isNetworking
  }
}
