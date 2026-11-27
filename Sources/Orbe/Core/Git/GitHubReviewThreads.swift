import Foundation

/// diff のどちらの側か（GitHub の `DiffSide`）。
enum GitHubDiffSide: String, Equatable {
  /// 古い側（マージベースの版）。
  case old = "LEFT"
  /// 新しい側（PR の先頭のコミットの版）。
  case new = "RIGHT"
}

/// レビューの種類（GitHub の `PullRequestReviewEvent`）。
enum GitHubReviewEvent: String, Equatable {
  case approve = "APPROVE"
  case comment = "COMMENT"
  case requestChanges = "REQUEST_CHANGES"
}

/// PR のレビューのやりとり（GitHub 上の一時点のもの）——行に付いたスレッド、自分の未送信のレビュー。
struct GitHubPullRequestReview: Equatable {
  struct Comment: Equatable {
    let id: String
    /// 書いた人の login。消えたアカウントなら nil。
    let author: String?
    /// 本文（書かれた Markdown のまま）。
    let body: String
    let createdAt: Date
    /// 未送信のレビューのコメント（レビューを送信するまで他の人に見えない）。
    let isPending: Bool
  }

  struct Thread: Equatable {
    let id: String
    let path: String
    let side: GitHubDiffSide
    /// 付いた行（その側の版の行。1 始まり）。今の diff に置けない（古い版に付いた・ファイル単位）なら nil。
    let line: Int?
    let isResolved: Bool
    let canReply: Bool
    let canResolve: Bool
    let canUnresolve: Bool
    /// 古い順に 100 件まで。
    let comments: [Comment]
  }

  struct PendingReview: Equatable {
    let id: String
    let commentCount: Int
  }

  /// 自分が PR の作者か。
  let viewerIsAuthor: Bool
  /// 読んだ時点の PR の先頭のコミット。
  let headCommit: String
  /// 自分の未送信のレビュー。無ければ nil。
  let pendingReview: PendingReview?
  var threads: [Thread]
}

/// レビューのやりとりの問い合わせの引数と、レスポンスの読み方。スレッドは `pageSize` 件ずつのページで読み、1 ページを 1 回の gh
/// 呼び出しにする。どのページでも PR の先頭のコミットを読み、読み手が 1 ページ目と比べられるようにする。
enum GitHubReviewQuery {
  /// 1 ページのスレッドの件数と、1 スレッドのコメントの件数（GitHub GraphQL の上限）。
  static let pageSize = 100

  private static let threadsFields =
    "nodes{id isResolved isOutdated path line diffSide subjectType viewerCanResolve viewerCanUnresolve "
    + "viewerCanReply comments(first:\(pageSize)){nodes{id author{login} body createdAt state}}} "
    + "pageInfo{hasNextPage endCursor}"

  /// 1 ページ目。PR の先頭のコミット・自分が作者か・未送信のレビューと、スレッドの先頭のページ。GitHub は未送信の
  /// レビューを書いた本人にしか返さないので、載るのは自分のもの（多くて 1 つ）だけとして、作者で絞らずに読む。
  static func firstPageArguments(_ id: GitHubItemID) -> [String] {
    arguments(
      id,
      fields: "headRefOid viewerDidAuthor "
        + "reviews(states:[PENDING],first:1){nodes{id comments{totalCount}}} "
        + "reviewThreads(first:\(pageSize)){\(threadsFields)}", after: nil)
  }

  /// スレッドの続きの 1 ページ。`after` は前のページの `endCursor`。
  static func nextPageArguments(_ id: GitHubItemID, after: String) -> [String] {
    arguments(
      id, fields: "headRefOid reviewThreads(first:\(pageSize),after:$after){\(threadsFields)}",
      after: after)
  }

  /// owner・name・カーソルは `-f`（文字列のまま）、番号は `-F`（整数）で渡す（`GitHubPullRequestQuery` と同じ）。
  private static func arguments(
    _ id: GitHubItemID, fields: String, after: String?
  ) -> [String] {
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

  /// 1 ページ目のレスポンス。
  struct FirstPage: Decodable {
    let review: GitHubPullRequestReview
    let threads: GitHubPage<GitHubPullRequestReview.Thread>.PageInfo

    init(from decoder: Decoder) throws {
      let payload = try ReviewResponse<FirstPayload>(from: decoder).data
      let node = payload.repository.pullRequest
      review = GitHubPullRequestReview(
        viewerIsAuthor: node.viewerDidAuthor, headCommit: node.headRefOid,
        pendingReview: node.reviews.nodes.first.map {
          .init(id: $0.id, commentCount: $0.comments.totalCount)
        }, threads: node.reviewThreads.nodes)
      threads = node.reviewThreads.pageInfo
    }
  }

  /// 続きの 1 ページのレスポンス。
  struct NextPage: Decodable {
    let headCommit: String
    let threads: GitHubPage<GitHubPullRequestReview.Thread>

    init(from decoder: Decoder) throws {
      let node = try ReviewResponse<NextPayload>(from: decoder).data.repository.pullRequest
      headCommit = node.headRefOid
      threads = node.reviewThreads
    }
  }
}

/// レスポンスの `data`。
private struct ReviewResponse<Payload: Decodable>: Decodable { let data: Payload }

private struct RepositoryNode<Node: Decodable>: Decodable { let pullRequest: Node }

private struct FirstPayload: Decodable { let repository: RepositoryNode<FirstNode> }

private struct NextPayload: Decodable { let repository: RepositoryNode<NextNode> }

private struct TotalCount: Decodable { let totalCount: Int }

/// 未送信のレビュー（`reviews(states:[PENDING])` の 1 項目）。
private struct PendingNode: Decodable {
  let id: String
  let comments: TotalCount
}

private struct FirstNode: Decodable {
  struct Reviews: Decodable { let nodes: [PendingNode] }
  let headRefOid: String
  let viewerDidAuthor: Bool
  let reviews: Reviews
  let reviewThreads: GitHubPage<GitHubPullRequestReview.Thread>
}

private struct NextNode: Decodable {
  let headRefOid: String
  let reviewThreads: GitHubPage<GitHubPullRequestReview.Thread>
}

extension GitHubPullRequestReview.Thread: Decodable {
  private enum CodingKeys: String, CodingKey {
    case id, isResolved, isOutdated, path, line, diffSide, subjectType, viewerCanResolve
    case viewerCanUnresolve
    case viewerCanReply, comments
  }

  private struct Comments: Decodable { let nodes: [GitHubPullRequestReview.Comment] }

  /// 古い版に付いた（outdated の）スレッド・ファイル単位のスレッド・Orbe が知らない側のスレッドは、行を持たない（今の diff に
  /// 置けない）として読む。outdated は行の値が残っていても置かない（GitHub の diff でも古い版の行のスレッドとして扱われる）。
  /// 知らない側でも一覧ごと読めなくしない。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let side = GitHubDiffSide(rawValue: try c.decodeIfPresent(String.self, forKey: .diffSide) ?? "")
    let isLine =
      try c.decodeIfPresent(String.self, forKey: .subjectType) != "FILE"
      && !(c.decodeIfPresent(Bool.self, forKey: .isOutdated) ?? false)
    self.init(
      id: try c.decode(String.self, forKey: .id), path: try c.decode(String.self, forKey: .path),
      side: side ?? .new,
      line: side != nil && isLine ? try c.decodeIfPresent(Int.self, forKey: .line) : nil,
      isResolved: try c.decode(Bool.self, forKey: .isResolved),
      canReply: try c.decode(Bool.self, forKey: .viewerCanReply),
      canResolve: try c.decode(Bool.self, forKey: .viewerCanResolve),
      canUnresolve: try c.decode(Bool.self, forKey: .viewerCanUnresolve),
      comments: try c.decode(Comments.self, forKey: .comments).nodes)
  }
}

extension GitHubPullRequestReview.Comment: Decodable {
  private enum CodingKeys: String, CodingKey {
    case id, author, body, createdAt, state
  }

  private struct Author: Decodable { let login: String? }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try c.decode(String.self, forKey: .id),
      author: try c.decodeIfPresent(Author.self, forKey: .author)?.login,
      body: try c.decode(String.self, forKey: .body),
      createdAt: try Date(c.decode(String.self, forKey: .createdAt), strategy: .iso8601),
      isPending: try c.decode(String.self, forKey: .state) == "PENDING")
  }
}
