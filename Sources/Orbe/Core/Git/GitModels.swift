import Foundation

// MARK: - worktree / branch（worktree パレット）

/// `git worktree list --porcelain` の 1 チェックアウト。
struct GitWorktree: Equatable {
  /// worktree の絶対パス。
  let path: String
  /// チェックアウト中のブランチ（`refs/heads/` を除いた正確な名前）。detached なら nil。
  let branch: String?
  /// HEAD の oid。
  let head: String
  /// 本体（main）worktree か。worktree 作成先の親ディレクトリ導出に使う。
  let isMain: Bool
  /// porcelain の `prunable <reason>` 行。ディスク上の実体が失われている（掃除の推定材料）。
  var isPrunable = false
  /// porcelain の `locked [reason]` 行の理由（理由が無ければ空文字）。locked でなければ nil。
  var lockReason: String?
}

/// `git worktree add -b` で切る新規ブランチ。追跡の指定（`--track` / `--no-track`）は git が
/// 新規ブランチにだけ許すので、名前と 1 つの値にまとめて「既存ブランチの checkout には付かない」を
/// 型で表す。
struct GitNewBranch: Equatable {
  let name: String
  /// base を upstream として追跡するか。
  let tracksBase: Bool
}

/// upstream との同期（`%(upstream:track)` を解釈した値）。同期済みは `GitUpstream.track` の nil。
enum GitUpstreamTrack: Equatable {
  /// upstream がリモートで消えている（`[gone]`）。
  case gone
  /// `[ahead N]` / `[behind M]` / `[ahead N, behind M]`。出ない側は 0。
  case counts(ahead: Int, behind: Int)
}

/// ローカルブランチの upstream。`for-each-ref` の upstream 系フィールドを 1 回だけ解釈した値で、
/// 表示（`short`）も最新化の git コマンド（`remote` / `remoteRef` / `ref`）もここから組む。
struct GitUpstream: Equatable {
  /// `%(upstream:short)`（`origin/x`。表示用）。
  let short: String
  /// `%(upstream)`（`refs/remotes/origin/x`。追跡 ref）。
  let ref: String
  /// `%(upstream:remotename)`（`origin`）。
  let remote: String
  /// `%(upstream:remoteref)`（`refs/heads/x`。remote 側の ref）。
  let remoteRef: String
  /// `%(upstream:track)`。nil は同期済み。
  let track: GitUpstreamTrack?
}

/// `git for-each-ref` の 1 ブランチ（local / remote 兼用）。
struct GitBranch: Equatable {
  /// `refs/heads/` / `refs/remotes/` を除いた正確な名前（local は `feat/x`・remote は `origin/feat/x`）。
  let name: String
  /// local は相対コミット日時（`1d前`）。remote は `author · 相対日時`。
  let relativeDate: String
  /// upstream。無ければ nil（remote ブランチは常に nil）。
  let upstream: GitUpstream?
  /// `%(push:remotename)`。git が解決する push 先の remote（`branch.<名前>.pushRemote` →
  /// `remote.pushDefault` → `branch.<名前>.remote`）で、ローカルブランチを追跡する行は `.`。
  /// 解決できなければ nil（remote ブランチは常に nil）。
  var pushRemote: String?

  /// `origin/feat/x` → `feat/x`（先頭のリモート名を落とす）。リモートのブランチや既定ブランチの値
  /// （`origin/main`）を、ローカルのブランチ名と比べるときに通す。
  static func localName(fromRemote name: String) -> String {
    let parts = name.split(separator: "/", maxSplits: 1)
    return parts.count == 2 ? String(parts[1]) : name
  }
}

// MARK: - GitHub（gh CLI）

/// GitHub のリポジトリ名（`owner/name`）。GitHub の名前は大小文字を区別しないので小文字で持ち、等値は
/// その文字列の等値で決まる。
struct GitHubRepoName: Hashable {
  /// 小文字の `owner/name`。
  let value: String

  init(nameWithOwner: String) {
    value = nameWithOwner.lowercased()
  }

  /// `owner/name` の owner。
  var owner: String { String(value.split(separator: "/", maxSplits: 1).first ?? "") }

  /// `owner/name` の name。
  var name: String { String(value.split(separator: "/", maxSplits: 1).last ?? "") }

  /// owner と名前から組む。どちらかが空なら nil。
  init?(owner: String, name: String) {
    guard !owner.isEmpty, !name.isEmpty else { return nil }
    self.init(nameWithOwner: "\(owner)/\(name)")
  }

  /// remote の URL から読む。GitHub かどうかは `isGitHub(remoteURL:)` で決め、`owner/name` はパス
  /// （scp 形式は `:` の後ろ）の最後の 2 段から `.git` と末尾の `/` を除いて読む。GitHub でない・読めない
  /// URL は nil。
  init?(remoteURL url: String) {
    guard Self.isGitHub(remoteURL: url) else { return nil }
    let path: Substring
    if let scheme = url.range(of: "://") {
      let rest = url[scheme.upperBound...]
      path = rest.firstIndex(of: "/").map { rest[$0...] } ?? ""
    } else if let colon = url.firstIndex(of: ":") {
      path = url[url.index(after: colon)...]
    } else {
      path = url[...]
    }
    let parts = path.split(separator: "/")
    guard parts.count >= 2 else { return nil }
    var name = parts[parts.count - 1]
    if name.hasSuffix(".git") { name = name.dropLast(4) }
    guard !name.isEmpty else { return nil }
    self.init(nameWithOwner: "\(parts[parts.count - 2])/\(name)")
  }

  /// github.com のリポジトリの URL か。URL の書き方（https・ssh://・scp 形式の `git@host:o/n`）ごとにホストを
  /// 取り出し、ホストが github.com か ssh.github.com（443 番の SSH）、または SSH の書き方でホストが
  /// `github.com-` で始まる別名（`github.com-work`。複数アカウントの ssh config の慣習）のときだけ真。
  /// `github.company.com` のような GitHub Enterprise は偽——問い合わせと書き込みは github.com を名指しする
  /// ので、別のホストの owner/name を github.com で読み書きしないため。可用性の判定
  /// （`GitRepo.originIsGitHub`）・台帳・GitHub タブの既定のリポジトリが共にこの 1 つの規則を読む。
  static func isGitHub(remoteURL url: String) -> Bool {
    guard let (host, isSSH) = host(of: url) else { return false }
    return host == "github.com" || host == "ssh.github.com"
      || (isSSH && host.hasPrefix("github.com-"))
  }

  /// URL のホスト（小文字）と、SSH の書き方か。`scheme://[user@]host[:port]/path` と scp 形式
  /// `[user@]host:path`（`:` が最初の `/` より前にある）を読む。どちらでもない（ローカルのパス）なら nil。
  private static func host(of url: String) -> (host: String, isSSH: Bool)? {
    let authority: Substring
    let isSSH: Bool
    if let scheme = url.range(of: "://") {
      let rest = url[scheme.upperBound...]
      authority = rest.prefix { $0 != "/" }
      isSSH = url[..<scheme.lowerBound].lowercased().contains("ssh")
    } else if let colon = url.firstIndex(of: ":"),
      !url[..<colon].contains("/")
    {
      authority = url[..<colon]
      isSSH = true
    } else {
      return nil
    }
    let hostAndPort = authority.split(separator: "@").last ?? ""
    let host = hostAndPort.prefix { $0 != ":" }
    return host.isEmpty ? nil : (host.lowercased(), isSSH)
  }
}

/// GitHub のどのリポジトリの、どのブランチか。行と PR の同一性の単位。
struct GitHubBranchRef: Hashable {
  let repo: GitHubRepoName
  let branch: String
}

/// GitHub に問い合わせたリポジトリの正式名（改名後の古い名前からも新しい名前が返る）。
enum GitHubRepositoryResolution: Equatable {
  case found(GitHubRepoName)
  /// 正式名を確かめられなかった。GitHub は「存在しない」と「今のアカウントから見えない private」を
  /// 同じ `NOT_FOUND` で返すので、問い合わせの失敗と区別しない。
  case unverified
}

/// PR の head のリポジトリを `headRepositoryOwner{login}` と `headRepository{name}` から読む。
/// `nameWithOwner` を読まないのは、古い gh の `gh pr list --json` に無い・空文字だから。
private struct PullRequestHeadRepository: Decodable {
  struct Owner: Decodable { let login: String? }
  struct Repository: Decodable { let name: String? }

  let headRepositoryOwner: Owner?
  let headRepository: Repository?

  /// どちらかが欠けるか空なら nil（head のリポジトリが消えている）。
  var name: GitHubRepoName? {
    GitHubRepoName(
      owner: headRepositoryOwner?.login ?? "", name: headRepository?.name ?? "")
  }
}

/// GraphQL の connection 1 ページ（`nodes` ＋ `pageInfo`）。
struct GitHubPage<Node: Decodable>: Decodable {
  struct PageInfo: Decodable {
    let hasNextPage: Bool
    /// 次のページの位置。ページが空なら nil。
    let endCursor: String?
  }

  let nodes: [Node]
  let pageInfo: PageInfo
}

/// `gh pr list --state all --head <branch> --json number,headRefName,state,baseRefName,headRepository,
/// headRepositoryOwner,url` の 1 PR。worktree の掃除で「レビュー中か／マージ済みか／未マージのまま閉じられたか」を
/// 見るための小さな形。
struct GitHubBranchPR: Decodable, Equatable {
  let number: Int
  let headRefName: String
  /// `OPEN` / `MERGED` / `CLOSED`。
  let state: String
  /// マージ先ブランチ。**表示専用**（安全判定はローカル git の事実だけで閉じる）。
  let baseRefName: String
  /// head 側のリポジトリ。消えていれば nil。
  let headRepository: GitHubRepoName?
  /// PR のページ（PR が置かれたリポジトリを指す。head のリポジトリとは限らない）。
  var url: String?

  /// head のリポジトリとブランチ。head のリポジトリが消えていれば nil（どのブランチとも等しくならない）。
  var head: GitHubBranchRef? {
    headRepository.map { GitHubBranchRef(repo: $0, branch: headRefName) }
  }

  /// `ref` のブランチの PR。`--head` はブランチ名でしか絞れず他人の fork の同名ブランチに立った PR も
  /// 返るので、ブランチと突き合わせるのは head が等しいものだけ（⌘T の clean と PR の自動の結び付けが
  /// 共にこの規則を通る）。並びは保つ。
  static func filter(_ pullRequests: [GitHubBranchPR], headedBy ref: GitHubBranchRef)
    -> [GitHubBranchPR]
  {
    pullRequests.filter { $0.head == ref }
  }
}

extension GitHubBranchPR {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      number: try container.decode(Int.self, forKey: .number),
      headRefName: try container.decode(String.self, forKey: .headRefName),
      state: try container.decode(String.self, forKey: .state),
      baseRefName: try container.decode(String.self, forKey: .baseRefName),
      headRepository: try PullRequestHeadRepository(from: decoder).name,
      url: try container.decodeIfPresent(String.self, forKey: .url))
  }

  private enum CodingKeys: String, CodingKey {
    case number, headRefName, state, baseRefName, url
  }
}

/// open 一覧（GraphQL の `issues` / `pullRequests`）の 1 項目。どのリポジトリの項目かは、一覧を取った
/// リポジトリが持つ。
struct GitHubOpenItem: Equatable {
  /// PR だけが持つ値。
  struct PullRequest: Equatable {
    let isDraft: Bool
    let review: GitHubItemSummary.ReviewDecision?
    let checks: GitHubItemSummary.Checks?
    /// 個人宛のレビュー依頼の login。
    var reviewers: [String]
    /// チーム宛のレビュー依頼（`org/slug`）。
    let teams: [String]
  }

  let number: Int
  let title: String
  let updatedAt: Date
  /// 作成者の login。消えたアカウントなら nil。
  let author: String?
  /// 担当者の login（先頭 10 人）。
  var assignees: [String]
  /// PR なら値がある。nil は Issue。
  var pullRequest: PullRequest?

  var kind: GitHubItemKind { pullRequest == nil ? .issue : .pr }

  /// 表示の規則（`GitHubItemText`）に渡す値。open 一覧の項目なので状態は open。
  var summary: GitHubItemSummary {
    GitHubItemSummary(
      title: title, state: .open,
      pullRequest: pullRequest.map {
        GitHubItemSummary.PullRequest(
          isDraft: $0.isDraft, review: $0.review, checks: $0.checks, author: author)
      })
  }
}

extension GitHubOpenItem: Decodable {
  private enum CodingKeys: String, CodingKey {
    case typename = "__typename"
    case number, title, updatedAt, author, assignees, isDraft, reviewDecision, commits,
      reviewRequests
  }

  /// 更新日時が読めない項目は、壊れた応答として、その一覧の取得を失敗で終える（並べ直しの鍵が無い）。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    number = try c.decode(Int.self, forKey: .number)
    title = try c.decode(String.self, forKey: .title)
    let updated = try c.decode(String.self, forKey: .updatedAt)
    guard let updatedAt = ISO8601DateFormatter().date(from: updated) else {
      throw DecodingError.dataCorruptedError(
        forKey: .updatedAt, in: c, debugDescription: "not an ISO 8601 date: \(updated)")
    }
    self.updatedAt = updatedAt
    author = try c.decodeIfPresent(OpenItemLogin.self, forKey: .author)?.login
    assignees =
      try c.decodeIfPresent(OpenItemLogins.self, forKey: .assignees)?.nodes?.compactMap {
        $0?.login
      } ?? []
    guard try c.decode(String.self, forKey: .typename) == "PullRequest" else {
      pullRequest = nil
      return
    }
    let reviewers =
      try c.decodeIfPresent(OpenItemReviewRequests.self, forKey: .reviewRequests)?.nodes?
      .compactMap { $0?.requestedReviewer } ?? []
    pullRequest = PullRequest(
      isDraft: try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false,
      review: try c.decodeIfPresent(String.self, forKey: .reviewDecision).flatMap(
        GitHubItemSummary.ReviewDecision.init(rawValue:)),
      checks: try c.decodeIfPresent(GitHubLastCommit.self, forKey: .commits)?.checks,
      reviewers: reviewers.compactMap { $0.typename == "User" ? $0.login : nil },
      teams: reviewers.compactMap { reviewer in
        guard reviewer.typename == "Team", let slug = reviewer.slug,
          let organization = reviewer.organization?.login
        else { return nil }
        return "\(organization)/\(slug)"
      })
  }
}

private struct OpenItemLogin: Decodable { let login: String? }
private struct OpenItemLogins: Decodable { let nodes: [OpenItemLogin?]? }

private struct OpenItemReviewRequests: Decodable {
  struct Node: Decodable { let requestedReviewer: OpenItemReviewer? }
  let nodes: [Node?]?
}

/// `User` は login、`Team` は所属の組織と slug。ほか（`Mannequin`・`Bot`）は読まない。
private struct OpenItemReviewer: Decodable {
  enum CodingKeys: String, CodingKey {
    case typename = "__typename"
    case login, slug, organization
  }

  let typename: String
  let login: String?
  let slug: String?
  let organization: OpenItemLogin?
}
