import Foundation

/// PR 1 件の中身（GitHub 上の一時点のもの）。
struct GitHubPullRequestContent: Equatable {
  /// 変更ファイルの変化の種類（GitHub の `PatchStatus`）。
  enum Change: String, Equatable {
    case added = "ADDED"
    case modified = "MODIFIED"
    case deleted = "DELETED"
    case renamed = "RENAMED"
    case copied = "COPIED"
    /// ファイルの種類が変わった（通常のファイルと symlink など）。
    case typeChanged = "CHANGED"
  }

  struct Commit: Equatable {
    let oid: String
    /// コミットメッセージの 1 行目。
    let headline: String
  }

  struct File: Equatable {
    let path: String
    let change: Change
    /// 確認済み（GitHub の Viewed）。確認済みだったが後の push で外れたファイルは偽。
    let isViewed: Bool
  }

  /// GraphQL の node ID（確認済みの書き込みが名指しする）。
  let nodeID: String
  let number: Int
  let title: String
  let url: String
  let isDraft: Bool
  let state: GitHubItemSummary.State
  /// 説明（書かれた Markdown のまま）。
  let body: String
  /// 作者の login。消えたアカウントなら nil。
  let author: String?
  let baseRefName: String
  let headRefName: String
  /// PR が比べる基準のベース側のコミット（ベースブランチに push があっても追従しない。マージベースではない）。
  let baseCommit: String
  /// PR の先頭のコミット。
  let headCommit: String
  /// PR のコミットの総数。GitHub は新しい側の 250 件までしか返さないので、`commits` の件数より多いことがある。
  let commitCount: Int
  /// PR のコミット。GitHub が返す新しい側の 250 件まで。
  var commits: [Commit]
  var files: [File]
}

/// PR の中身の問い合わせの引数と、答えの読み方。コミットと変更ファイルは `pageSize` 件ずつのページで読み、1 ページを
/// 1 回の gh 呼び出しにする（`GitHubCLI` の時間上限の打ち切りは 1 回の呼び出しごとに効く）。どのページでも基準のベース側の
/// コミットと PR の先頭のコミットを読み、読み手が 1 ページ目と比べられるようにする。
enum GitHubPullRequestQuery {
  /// 1 ページの件数（GitHub GraphQL の上限）。
  static let pageSize = 100

  /// コミットと変更ファイルのどちらの続きか。
  enum Connection: String {
    case commits, files
  }

  private static let commitsFields =
    "nodes{commit{oid messageHeadline}} pageInfo{hasNextPage endCursor}"
  private static let filesFields =
    "nodes{path changeType viewerViewedState} pageInfo{hasNextPage endCursor}"

  /// 1 ページ目。PR の値と、コミット・変更ファイルの先頭のページ。
  static func firstPageArguments(_ id: GitHubItemID) -> [String] {
    arguments(
      id,
      fields: "id number title url isDraft state body author{login} baseRefName headRefName "
        + "baseRefOid headRefOid commits(first:\(pageSize)){totalCount \(commitsFields)} "
        + "files(first:\(pageSize)){\(filesFields)}", after: nil)
  }

  /// 続きの 1 ページ。`after` は前のページの `endCursor`。
  static func nextPageArguments(_ id: GitHubItemID, connection: Connection, after: String)
    -> [String]
  {
    let fields =
      switch connection {
      case .commits: commitsFields
      case .files: filesFields
      }
    return arguments(
      id,
      fields: "baseRefOid headRefOid \(connection.rawValue)(first:\(pageSize),after:$after)"
        + "{\(fields)}", after: after)
  }

  /// owner・name・カーソルは `-f`（文字列のまま）、番号は `-F`（整数）で渡す（`resolveRepositoryArguments` と同じく、
  /// 数字だけの名前を整数に変えないため）。
  private static func arguments(_ id: GitHubItemID, fields: String, after: String?) -> [String] {
    let declarations =
      "$owner:String!,$name:String!,$number:Int!" + (after == nil ? "" : ",$after:String!")
    var args = [
      "api", "graphql", "--hostname", "github.com", "-f",
      "query=query(\(declarations)){repository(owner:$owner,name:$name){"
        + "pullRequest(number:$number){\(fields)}}}",
      "-f", "owner=\(id.repo.owner)", "-f", "name=\(id.repo.name)", "-F", "number=\(id.number)",
    ]
    if let after { args += ["-f", "after=\(after)"] }
    return args
  }

  /// 1 ページ目の答え。
  struct FirstPage: Decodable {
    let content: GitHubPullRequestContent
    let commits: GitHubPage<GitHubPullRequestContent.Commit>.PageInfo
    let files: GitHubPage<GitHubPullRequestContent.File>.PageInfo

    init(from decoder: Decoder) throws {
      let node = try PullRequestNode<FirstNode>.read(decoder)
      guard let state = GitHubItemSummary.State(rawValue: node.state) else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "unknown state \(node.state)"))
      }
      content = GitHubPullRequestContent(
        nodeID: node.id, number: node.number, title: node.title, url: node.url,
        isDraft: node.isDraft, state: state, body: node.body, author: node.author?.login,
        baseRefName: node.baseRefName, headRefName: node.headRefName,
        baseCommit: node.baseRefOid, headCommit: node.headRefOid,
        commitCount: node.commits.totalCount, commits: node.commits.nodes, files: node.files.nodes)
      commits = node.commits.pageInfo
      files = node.files.pageInfo
    }
  }

  /// 続きの 1 ページの答え。
  struct NextPage: Decodable {
    let baseCommit: String
    let headCommit: String
    let commits: GitHubPage<GitHubPullRequestContent.Commit>?
    let files: GitHubPage<GitHubPullRequestContent.File>?

    init(from decoder: Decoder) throws {
      let node = try PullRequestNode<NextNode>.read(decoder)
      baseCommit = node.baseRefOid
      headCommit = node.headRefOid
      commits = node.commits
      files = node.files
    }
  }
}

/// `data.repository.pullRequest` を読む。
private struct PullRequestNode<Node: Decodable>: Decodable {
  struct Payload: Decodable { let repository: Repository }
  struct Repository: Decodable { let pullRequest: Node }
  let data: Payload

  static func read(_ decoder: Decoder) throws -> Node {
    try PullRequestNode(from: decoder).data.repository.pullRequest
  }
}

private struct FirstNode: Decodable {
  struct Author: Decodable { let login: String? }
  let id: String
  let number: Int
  let title: String
  let url: String
  let isDraft: Bool
  let state: String
  let body: String
  let author: Author?
  let baseRefName: String
  let headRefName: String
  let baseRefOid: String
  let headRefOid: String
  let commits: CountedCommits
  let files: GitHubPage<GitHubPullRequestContent.File>
}

/// 1 ページ目のコミットの列（総数つき）。
private struct CountedCommits: Decodable {
  let totalCount: Int
  let nodes: [GitHubPullRequestContent.Commit]
  let pageInfo: GitHubPage<GitHubPullRequestContent.Commit>.PageInfo
}

private struct NextNode: Decodable {
  let baseRefOid: String
  let headRefOid: String
  let commits: GitHubPage<GitHubPullRequestContent.Commit>?
  let files: GitHubPage<GitHubPullRequestContent.File>?
}

/// PR のコミットの列の 1 項目（`{commit{oid messageHeadline}}`）。
extension GitHubPullRequestContent.Commit: Decodable {
  private enum CodingKeys: String, CodingKey {
    case commit, oid, messageHeadline
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self).nestedContainer(
      keyedBy: CodingKeys.self, forKey: .commit)
    self.init(
      oid: try c.decode(String.self, forKey: .oid),
      headline: try c.decode(String.self, forKey: .messageHeadline))
  }
}

extension GitHubPullRequestContent.File: Decodable {
  private enum CodingKeys: String, CodingKey {
    case path, changeType, viewerViewedState
  }

  /// Orbe が知らない変化の種類（GitHub が今後足すもの）は「変更」として読む（一覧ごと読めなくしない）。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      path: try c.decode(String.self, forKey: .path),
      change: GitHubPullRequestContent.Change(
        rawValue: try c.decode(String.self, forKey: .changeType)) ?? .modified,
      isViewed: try c.decodeIfPresent(String.self, forKey: .viewerViewedState) == "VIEWED")
  }
}
