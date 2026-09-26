import Foundation

/// remote 1 本が GitHub のどのリポジトリか。
enum DispatchRemoteRepository: Equatable {
  /// GitHub が答えた正式名。
  case github(GitHubRepoName)
  /// GitHub の remote でない。
  case notGitHub
  /// GitHub の remote だが、正式名を確かめられない（存在しない・今のアカウントから見えない・問い合わせの
  /// 失敗・URL からリポジトリ名を読めない・remote の一覧を読めない）。
  case unverified
}

/// 行（worktree / branch）が GitHub のどのリポジトリのどのブランチか。
///
/// `unverified` を `notGitHub` と同じに読んではならない——clean は `notGitHub` を「PR を確かめて 0 件」と
/// 読むので、確かめられない行を安全群に入れてしまう。読み手は 3 つを網羅して分岐する。
enum DispatchRowIdentity: Equatable {
  case ref(GitHubBranchRef)
  case notGitHub
  case unverified
}

/// remote の台帳。remote ごとに GitHub のどのリポジトリかを持つ。provider が remote の一覧（git）と
/// 正式名の答え（キャッシュ）から、そのつど導く（保存しない）。
enum DispatchRemoteLedger: Equatable {
  /// GitHub の remote に、正式名の答えをまだ一度も得ていないもの（問い合わせ中・未発行）がある。
  case pending
  case settled(Resolved)

  /// 全 remote の答えが揃った台帳。
  struct Resolved: Equatable {
    /// push 先を持たない行（upstream も push 先の設定も無い・ローカルブランチを追跡する）を push 先と
    /// みなす remote。fetch を信頼する remote（`DispatchBranchSync.trustedRemote`）とは別の関心で、
    /// 片方を変えてももう片方は変わらない。
    static let defaultRemote = "origin"

    /// remote 名 → 値。`nil` = remote の一覧を読めなかった（どの問いにも `unverified` を返す）。
    let repositories: [String: DispatchRemoteRepository]?

    /// push 先の remote（`GitBranch.pushRemote`）の値。push 先が無い・`.`（ローカル追跡）なら既定 remote
    /// の値（既定 remote が無ければ push される先が無いので `notGitHub`）。台帳に無い名前（URL を直接
    /// 書いた remote・存在しない remote）は `unverified`——git が既定 remote 以外へ push すると言っている
    /// 行を、既定 remote の同名ブランチとみなさない。
    func repository(forPushRemote name: String?) -> DispatchRemoteRepository {
      guard let repositories else { return .unverified }
      guard let name, name != "." else { return repositories[Self.defaultRemote] ?? .notGitHub }
      return repositories[name] ?? .unverified
    }

    /// 既定 remote の正式名を確かめられない（一覧の紐付けを省く判定）。
    var defaultRemoteUnverified: Bool {
      repository(forPushRemote: nil) == .unverified
    }

    /// remote 追跡ブランチ（`origin/feat/x`）。remote 名は台帳の名前で切り分ける（`/` を含む remote 名も
    /// あるので、一致する最も長い名前を採る）。どの remote にも一致しなければ `notGitHub`。
    func remoteBranch(_ name: String) -> DispatchRowIdentity {
      guard let repositories else { return .unverified }
      let remote = repositories.keys.filter { name.hasPrefix($0 + "/") }.max { $0.count < $1.count }
      guard let remote, let repository = repositories[remote] else { return .notGitHub }
      return Self.identity(repository, branch: String(name.dropFirst(remote.count + 1)))
    }

    static func identity(_ repository: DispatchRemoteRepository, branch: String)
      -> DispatchRowIdentity
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
    var repositories: [String: DispatchRemoteRepository] = [:]
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

/// 行の同一性を求める唯一の口。チップ・PR 行の行き先（`DispatchSectionBuilder`）と clean の PR の事実
/// （provider の `branchPRStates`）が、同じこの型を通る。
///
/// ローカルブランチは（push 先の remote の正式名, ローカル名）。PR の head は自分が push したブランチ
/// なので、git が push 先として解決する remote がそのリポジトリになる。upstream（pull する元）は base
/// （`origin/main`）や積み上げ元を指しうるので使わない。ブランチ名がローカル名なのは、既定の
/// `push.default=simple` では名前の違う upstream へは push できず、push されるのはローカル名だから。
struct DispatchRowIdentities {
  let resolved: DispatchRemoteLedger.Resolved
  /// ローカル名 → ブランチ（同名は先勝ち）。
  private let localBranches: [String: GitBranch]

  init(resolved: DispatchRemoteLedger.Resolved, localBranches: [GitBranch]) {
    self.resolved = resolved
    self.localBranches = Dictionary(
      localBranches.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// ローカルブランチ（worktree のブランチを含む）。
  func local(_ name: String) -> DispatchRowIdentity {
    DispatchRemoteLedger.Resolved.identity(
      resolved.repository(forPushRemote: localBranches[name]?.pushRemote), branch: name)
  }

  /// remote 追跡ブランチ（`origin/feat/x`）。
  func remote(_ name: String) -> DispatchRowIdentity {
    resolved.remoteBranch(name)
  }
}
