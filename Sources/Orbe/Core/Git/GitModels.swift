import Foundation

// MARK: - worktree / branch（Dispatch パレット）

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
}

// MARK: - GitHub（gh CLI）

/// GitHub のリポジトリ名（`owner/name`）。GitHub の名前は大小文字を区別しないので小文字で持ち、等値は
/// その文字列の等値で決まる。API から作る口は、owner と名前から（PR の head）と、正式名の問い合わせの
/// 応答から（`init(nameWithOwner:)`）の 2 つだけ——`Decodable` にしないのは、PR の head を
/// `nameWithOwner` で読めなくするため（古い gh の `gh pr list --json` は空文字を返すか、キーごと出さない）。
struct GitHubRepoName: Hashable {
  /// 小文字の `owner/name`。
  let value: String

  init(nameWithOwner: String) {
    value = nameWithOwner.lowercased()
  }

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

  /// GitHub の remote の URL か（「URL に github.com を含むか」。SSH のホスト別名 `github.com-work` 等も
  /// 拾う）。可用性の判定（`GitRepo.originIsGitHub`）と台帳が共にこの 1 つの規則を読む。
  static func isGitHub(remoteURL url: String) -> Bool {
    url.contains("github.com")
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
  /// そのリポジトリは存在しない（見えない）。
  case notFound
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

/// 番号で同一性を持つ GitHub の項目。open 一覧を取り直す途中、前回の一覧との境目を探すのに使う。
protocol GitHubNumbered {
  var number: Int { get }
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

/// open issue 一覧（GraphQL `issues`）の 1 issue。
struct GitHubIssue: Decodable, Equatable, GitHubNumbered {
  let number: Int
  let title: String
}

/// `gh pr list --state all --head <branch> --json number,headRefName,state,baseRefName,headRepository,
/// headRepositoryOwner` の 1 PR。worktree の掃除で「レビュー中か／マージ済みか／未マージのまま閉じられたか」を
/// 見るための小さな形で、`GitHubPullRequest`（title 必須）ではこの JSON をデコードできない。
struct GitHubBranchPR: Decodable, Equatable {
  let number: Int
  let headRefName: String
  /// `OPEN` / `MERGED` / `CLOSED`。
  let state: String
  /// マージ先ブランチ。**表示専用**（安全判定はローカル git の事実だけで閉じる）。
  let baseRefName: String
  /// head 側のリポジトリ。消えていれば nil。
  let headRepository: GitHubRepoName?

  /// head のリポジトリとブランチ。`--head` はブランチ名でしか絞れず他人の fork の同名ブランチに
  /// 立った PR も返るので、worktree と突き合わせるのはこれが等しいものだけ。head のリポジトリが
  /// 消えていれば nil（どの worktree とも等しくならない）。
  var head: GitHubBranchRef? {
    headRepository.map { GitHubBranchRef(repo: $0, branch: headRefName) }
  }
}

/// open PR 一覧（GraphQL `pullRequests`）の 1 PR。
struct GitHubPullRequest: Decodable, Equatable, GitHubNumbered {
  let number: Int
  let title: String
  let headRefName: String
  /// `REVIEW_REQUIRED` / `APPROVED` / `CHANGES_REQUESTED` / null。
  let reviewDecision: String?
  /// head 側のリポジトリ。消えていれば nil。
  let headRepository: GitHubRepoName?

  /// head のリポジトリとブランチ（行との同一性）。head のリポジトリが消えていれば nil で、どの行とも
  /// 等しくならない。
  var head: GitHubBranchRef? {
    headRepository.map { GitHubBranchRef(repo: $0, branch: headRefName) }
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
      headRepository: try PullRequestHeadRepository(from: decoder).name)
  }

  private enum CodingKeys: String, CodingKey {
    case number, headRefName, state, baseRefName
  }
}

extension GitHubPullRequest {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      number: try container.decode(Int.self, forKey: .number),
      title: try container.decode(String.self, forKey: .title),
      headRefName: try container.decode(String.self, forKey: .headRefName),
      reviewDecision: try container.decodeIfPresent(String.self, forKey: .reviewDecision),
      headRepository: try PullRequestHeadRepository(from: decoder).name)
  }

  private enum CodingKeys: String, CodingKey {
    case number, title, headRefName, reviewDecision
  }
}
