import Foundation

/// worktree の今の PR の答えの形——出せない理由・作成の入口の材料・手元とのずれ。
extension BranchPullRequest {
  /// 出せない理由。
  enum Unavailable: Equatable {
    case notGit
    case detached
    case defaultBranch
    case ghMissing
    case ghUnauthed
    case notGitHub
    case unverified
    case failed(GitHubFailure)
  }

  /// ブランチが GitHub に在るか。
  enum Published: Equatable {
    case checking
    case yes
    case no
    /// 問い合わせが失敗した。
    case unknown
  }

  /// open の PR が無いときの、作成の入口の材料。
  struct Creation: Equatable {
    let branch: String
    let defaultBranch: String
    /// 既定のブランチの追跡 ref に対する先行の数（追跡 ref が手元に無ければ nil）。
    let ahead: Int?
    let url: URL?
    let ref: GitHubBranchRef
    var published: Published
  }

  enum Answer: Equatable {
    case reading
    case unavailable(Unavailable)
    case noPullRequest(Creation)
    case pullRequest(PullRequestState)

    static func == (lhs: Answer, rhs: Answer) -> Bool {
      switch (lhs, rhs) {
      case (.reading, .reading): true
      case (.unavailable(let a), .unavailable(let b)): a == b
      case (.noPullRequest(let a), .noPullRequest(let b)): a == b
      case (.pullRequest(let a), .pullRequest(let b)): a === b
      default: false
      }
    }
  }

  /// PR があるときの手元とのずれ。
  enum Drift: Equatable {
    /// この worktree で PR の先頭をチェックアウト済み。
    case inSync
    /// 手元にしか無いコミット（未 push）の数と、PR にしか無いコミット（未取得）の数。
    case diverged(ahead: Int, behind: Int)
    /// ずれを数えない（PR の先頭のコミットが手元に無い・読めない・浅いクローン）が、手元の HEAD が PR の先頭と違う。
    case differs
  }
}
