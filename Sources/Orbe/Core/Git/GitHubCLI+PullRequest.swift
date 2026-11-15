import Foundation

/// PR の中身の読み取りと、変更ファイルの確認済み（GitHub の Files changed の Viewed）の書き込み。問い合わせ先はリポジトリ名で
/// 決まるので、作業ディレクトリはリポジトリに依らない。どちらもメインスレッドで返る。
extension GitHubCLI {
  /// PR 1 件の中身を、一時点のものとして揃えて読む。コミットと変更ファイルはページングして全件を読み、ページの間に push や
  /// ベースブランチの付け替えが入った（ベースとヘッドのコミットが 1 ページ目と違う）ら最初から読み直す。読み直しは 1 回まで
  /// で、なお違えば失敗（gh は何も言っていないので失敗の理由は空）。途中のページの失敗は全体の失敗——半分の一覧を返さない。
  func pullRequestContent(
    _ id: GitHubItemID,
    completion: @escaping (Result<GitHubPullRequestContent, GitHubFailure>) -> Void
  ) {
    queue.async {
      let result: Result<GitHubPullRequestContent, GitHubFailure> =
        self.resolveGh().map { gh in
          for _ in 0..<2 {
            switch PullRequestContentRead(cli: self, gh: gh, id: id).read() {
            case .read(let content): return .success(content)
            case .failed(let failure): return .failure(failure)
            case .moved: continue
            }
          }
          return .failure(.reason(""))
        } ?? .failure(.reason(""))
      DispatchQueue.main.async { completion(result) }
    }
  }

  /// 変更ファイルの確認済みを、`paths` まとめて付ける（`viewed` が偽なら外す）。`itemsPerQuery` 件ごとに 1 回のクエリ
  /// にし、順に送る。一部だけ成功することがあるので、成功したパスと失敗の種類を返す。失敗した回より後の回は送らない（成功
  /// しなかったパスに入る）。
  func setViewed(
    _ viewed: Bool, paths: [String], pullRequest nodeID: String,
    completion: @escaping (GitHubViewedWrite) -> Void
  ) {
    let chunks = stride(from: 0, to: paths.count, by: Self.itemsPerQuery).map {
      Array(paths[$0..<min($0 + Self.itemsPerQuery, paths.count)])
    }
    queue.async {
      var written: Set<String> = []
      var failure: GitHubFailure?
      if let gh = self.resolveGh() {
        for chunk in chunks {
          let out = self.runSync(
            gh, GitHubViewedMutation.arguments(viewed, paths: chunk, pullRequest: nodeID),
            cwd: NSHomeDirectory())
          let passed = GitHubViewedMutation.written(from: out.stdout, paths: chunk)
          written.formUnion(passed)
          guard passed.count == chunk.count else {
            failure = out.failure ?? .reason("")
            break
          }
        }
      } else if !chunks.isEmpty {
        failure = .reason("")
      }
      let result = GitHubViewedWrite(written: written, failure: failure)
      DispatchQueue.main.async { completion(result) }
    }
  }
}

/// 確認済みの書き込みの結果。
struct GitHubViewedWrite: Equatable {
  /// 書き込みが成功したパス。
  let written: Set<String>
  /// 成功しなかったパスがあれば、その失敗。
  let failure: GitHubFailure?
}

/// 確認済みの書き込み（GraphQL の `markFileAsViewed` / `unmarkFileAsViewed`）の引数とレスポンスの読み方。パスごとの書き込みを
/// 別名（`f0`）で並べて 1 回に入れる。
enum GitHubViewedMutation {
  /// PR の ID とパスは `-f`（文字列のまま）で渡す——パスをクエリ文に直接書かない。
  static func arguments(_ viewed: Bool, paths: [String], pullRequest nodeID: String) -> [String] {
    let field = viewed ? "markFileAsViewed" : "unmarkFileAsViewed"
    let declarations = ["$pr:ID!"] + paths.indices.map { "$p\($0):String!" }
    let fields = paths.indices.map {
      "f\($0):\(field)(input:{pullRequestId:$pr,path:$p\($0)}){clientMutationId}"
    }
    var args = [
      "api", "graphql", "--hostname", "github.com", "-f",
      "query=mutation(\(declarations.joined(separator: ","))){\(fields.joined(separator: " "))}",
      "-f", "pr=\(nodeID)",
    ]
    for (index, path) in paths.enumerated() { args += ["-f", "p\(index)=\(path)"] }
    return args
  }

  /// レスポンスの `data` に値が載った別名のパス。gh が 0 以外で終わっても、成功した分は `data` に載る。
  static func written(from stdout: Data, paths: [String]) -> Set<String> {
    guard let data = (try? JSONDecoder().decode(Response.self, from: stdout))?.data else {
      return []
    }
    return Set(
      paths.enumerated().compactMap { index, path in
        data["f\(index)"].flatMap { $0 } == nil ? nil : path
      })
  }

  private struct Response: Decodable {
    let data: [String: MutationPayload?]?
  }
}

/// 別名ごとの書き込みのレスポンス。値が載っているか（null でないか）だけを読む。
private struct MutationPayload: Decodable {}

private enum ContentReading {
  case read(GitHubPullRequestContent)
  case failed(GitHubFailure)
  /// 読んでいる間にベースかヘッドのコミットが動いた。
  case moved
}

/// PR の中身を最初のページから読む 1 回分の処理。
private struct PullRequestContentRead {
  let cli: GitHubCLI
  let gh: String
  let id: GitHubItemID

  private enum Rest<Node> {
    case nodes([Node])
    case stopped(ContentReading)
  }

  func read() -> ContentReading {
    let first: Result<GitHubPullRequestQuery.FirstPage, GitHubFailure> = cli.decodeSync(
      gh, GitHubPullRequestQuery.firstPageArguments(id), cwd: NSHomeDirectory())
    let page: GitHubPullRequestQuery.FirstPage
    switch first {
    case .failure(let failure): return .failed(failure)
    case .success(let read): page = read
    }
    var content = page.content
    switch rest(.commits, after: page.commits, of: content, \.commits) {
    case .stopped(let reading): return reading
    case .nodes(let commits): content.commits += commits
    }
    switch rest(.files, after: page.files, of: content, \.files) {
    case .stopped(let reading): return reading
    case .nodes(let files): content.files += files
    }
    return .read(content)
  }

  /// `connection` の続きのページを、最後のページまで読み足す。ベースとヘッドのコミットが `content` と違うページが来たら `.moved`。
  private func rest<Node>(
    _ connection: GitHubPullRequestQuery.Connection, after start: GitHubPage<Node>.PageInfo,
    of content: GitHubPullRequestContent,
    _ nodes: KeyPath<GitHubPullRequestQuery.NextPage, GitHubPage<Node>?>
  ) -> Rest<Node> {
    var read: [Node] = []
    var pageInfo = start
    while pageInfo.hasNextPage, let cursor = pageInfo.endCursor {
      let page: Result<GitHubPullRequestQuery.NextPage, GitHubFailure> = cli.decodeSync(
        gh, GitHubPullRequestQuery.nextPageArguments(id, connection: connection, after: cursor),
        cwd: NSHomeDirectory())
      let next: GitHubPullRequestQuery.NextPage
      switch page {
      case .failure(let failure): return .stopped(.failed(failure))
      case .success(let decoded): next = decoded
      }
      guard next.baseCommit == content.baseCommit, next.headCommit == content.headCommit else {
        return .stopped(.moved)
      }
      guard let more = next[keyPath: nodes] else { return .stopped(.failed(.reason(""))) }
      read += more.nodes
      pageInfo = more.pageInfo
    }
    return .nodes(read)
  }
}
