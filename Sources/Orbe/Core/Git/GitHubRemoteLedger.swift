import Foundation

/// remote 1 本が GitHub のどのリポジトリか。
enum GitHubRemoteRepository: Equatable {
  /// GitHub が答えた正式名。
  case github(GitHubRepoName)
  /// GitHub の remote でない。
  case notGitHub
  /// GitHub の remote だが、正式名を確かめられない（存在しない・今のアカウントから見えない・問い合わせの
  /// 失敗・URL からリポジトリ名を読めない・remote の一覧を読めない）。
  case unverified
}

/// ローカルのブランチ（worktree のブランチを含む）が GitHub のどのリポジトリのどのブランチか。
///
/// `unverified` を `notGitHub` と同じに読んではならない——clean は `notGitHub` を「PR を確かめて 0 件」と
/// 読むので、確かめられない行を安全群に入れてしまう。読み手は 3 つを網羅して分岐する。
enum GitHubBranchIdentity: Equatable {
  case ref(GitHubBranchRef)
  case notGitHub
  case unverified
}

/// remote の台帳。remote ごとに GitHub のどのリポジトリかを持つ。使う側が remote の一覧（git）と
/// 正式名の答え（キャッシュ）から、そのつど導く（保存しない）。
enum GitHubRemoteLedger: Equatable {
  /// GitHub の remote に、正式名の答えをまだ一度も得ていないもの（問い合わせ中・未発行）がある。
  case pending
  case settled(Resolved)

  /// 全 remote の答えが揃った台帳。
  struct Resolved: Equatable {
    /// push 先を持たない行（`branch.<名前>.pushRemote`・`remote.pushDefault`・`branch.<名前>.remote` の
    /// どれも無い・ローカルブランチを追跡する）を push 先とみなす remote。fetch を信頼する remote
    /// （`WorktreePaletteBranchSync.trustedRemote`）とは別の関心で、片方を変えてももう片方は変わらない。
    static let defaultRemote = "origin"

    /// remote 名 → 値。`nil` = remote の一覧を読めなかった（どの問いにも `unverified` を返す）。
    let repositories: [String: GitHubRemoteRepository]?

    /// push 先の remote（`GitBranch.pushRemote`）の値。push 先が無い・`.`（ローカル追跡）なら既定 remote
    /// の値（既定 remote が無ければ push される先が無いので `notGitHub`）。台帳に無い名前（URL を直接
    /// 書いた remote・存在しない remote）は `unverified`——git が既定 remote 以外へ push すると言っている
    /// 行を、既定 remote の同名ブランチとみなさない。
    func repository(forPushRemote name: String?) -> GitHubRemoteRepository {
      guard let repositories else { return .unverified }
      guard let name, name != "." else { return repositories[Self.defaultRemote] ?? .notGitHub }
      return repositories[name] ?? .unverified
    }

    static func identity(_ repository: GitHubRemoteRepository, branch: String)
      -> GitHubBranchIdentity
    {
      switch repository {
      case .github(let repo): return .ref(GitHubBranchRef(repo: repo, branch: branch))
      case .notGitHub: return .notGitHub
      case .unverified: return .unverified
      }
    }
  }

  /// remote の一覧（remote 名 → URL。`nil` = 読めなかった）と正式名の答え（URL から読んだ名前 → 答え）
  /// から台帳を導く。答えの無い GitHub の remote が 1 本でもあれば未確定——行が使わない remote まで
  /// 待つが、remote は通常 1〜3 本で待ちは変わらず、「確定したか」の規則が 1 つで済む。
  init(remotes: [String: String]?, answers: [GitHubRepoName: GitHubRepositoryResolution]) {
    guard let remotes else {
      self = .settled(Resolved(repositories: nil))
      return
    }
    var repositories: [String: GitHubRemoteRepository] = [:]
    for (remote, url) in remotes {
      if let read = GitHubRepoName(remoteURL: url) {
        switch answers[read] {
        case .found(let name): repositories[remote] = .github(name)
        case .unverified: repositories[remote] = .unverified
        case nil:
          self = .pending
          return
        }
      } else if GitHubRepoName.isGitHub(remoteURL: url) {
        repositories[remote] = .unverified
      } else {
        repositories[remote] = .notGitHub
      }
    }
    self = .settled(Resolved(repositories: repositories))
  }
}

/// ブランチの同一性を求める唯一の口。⌘T の clean の PR の事実とブランチの PR の問い合わせ先が、同じこの型を通る。
///
/// ローカルブランチは（push 先の remote の正式名, ローカル名）。PR の head は自分が push したブランチ
/// なので、git が push 先として解決する remote がそのリポジトリになる——base（`origin/main`）や積み上げ元を
/// 追跡するブランチも、base から出た PR ではなく自分の PR に紐づく。ブランチ名がローカル名なのは、既定の
/// `push.default=simple` で push されるのがローカル名だから。
struct GitHubBranchIdentities {
  private let resolved: GitHubRemoteLedger.Resolved
  /// ローカル名 → ブランチ（同名は先勝ち）。
  private let localBranches: [String: GitBranch]

  init(resolved: GitHubRemoteLedger.Resolved, localBranches: [GitBranch]) {
    self.resolved = resolved
    self.localBranches = Dictionary(
      localBranches.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// ローカルブランチ（worktree のブランチを含む）。
  func local(_ name: String) -> GitHubBranchIdentity {
    GitHubRemoteLedger.Resolved.identity(
      resolved.repository(forPushRemote: localBranches[name]?.pushRemote), branch: name)
  }
}
