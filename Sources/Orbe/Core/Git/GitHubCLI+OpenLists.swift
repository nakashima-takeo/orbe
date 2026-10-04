import Foundation

/// GitHub タブの問い合わせと書き込み（既定のリポジトリ・open 一覧・レビュー依頼・自分の追加）。
extension GitHubCLI {
  /// `root` で gh が既定とするリポジトリ（set-default → upstream → github → origin の順に gh が選ぶ）の
  /// 正式名。gh の有無と認証を先に確かめて理由を分け、`gh repo view` が失敗した・読めないときは
  /// 「見つからない」（オフラインと区別しない）。github.com 以外のホスト（GitHub Enterprise）のリポジトリも
  /// 「見つからない」——以後の問い合わせと書き込みは github.com を名指しするので、同じ owner/name の別の
  /// リポジトリを読み書きしないため。メインで返る。
  func defaultRepository(
    root: String,
    completion: @escaping (Result<GitHubRepoName, GitHubRepositoryUnavailable>) -> Void
  ) {
    probe(cwd: root, isGitHub: true) { availability in
      switch availability {
      case .ghMissing: return completion(.failure(.ghMissing))
      case .ghUnauthed: return completion(.failure(.ghUnauthed))
      case .ready, .notGitHub: break
      }
      self.queue.async {
        let response: DefaultRepositoryResponse? = self.resolveGh().flatMap {
          self.fetchSync($0, Self.defaultRepositoryArguments, cwd: root)
        }
        let result: Result<GitHubRepoName, GitHubRepositoryUnavailable> =
          response.flatMap { response in
            GitHubRepoName.isGitHub(remoteURL: response.url)
              ? .success(GitHubRepoName(nameWithOwner: response.nameWithOwner)) : nil
          } ?? .failure(.notFound)
        DispatchQueue.main.async { completion(result) }
      }
    }
  }

  static let defaultRepositoryArguments = ["repo", "view", "--json", "nameWithOwner,url"]

  /// open 一覧の上限。開くたびに裏で取り続ける総量の安全弁で、問い合わせの回数（＝レート消費）と、
  /// 裏で gh が動き続ける時間を抑える。1 ページ `openListPageSize` 件なので issue 10・PR 5 回まで。
  /// PR はレビュー状態・CI・レビュー依頼の算出で重く、PR の多いリポジトリでは 1 ページ 7〜9 秒かかる
  /// （`timeout` の内に収まる）。
  static let openIssueLimit = 1000
  static let openPullRequestLimit = 500
  /// 1 ページの件数（GitHub GraphQL の上限）。
  static let openListPageSize = 100

  /// `repo` の open issue 一覧を作成の新しい順に `openIssueLimit` まで、ページが届くたびに `page` へ渡す。
  /// `finished` は最後に 1 回だけ呼ぶ: `true` = 次のページが無い／上限に達した、`false` = 途中で失敗した
  /// （gh 未解決・非 0 終了・1 ページの打ち切り・デコード失敗）。失敗までに渡したページは有効なまま。
  /// 問い合わせ先はリポジトリ名で決まるので、作業ディレクトリはリポジトリに依らない。
  func openIssues(
    repo: GitHubRepoName, page: @escaping ([GitHubOpenItem]) -> Void,
    finished: @escaping (Bool) -> Void
  ) {
    fetchPages(
      limit: Self.openIssueLimit,
      arguments: { Self.openIssuesPageArguments(repo: repo, first: $0, after: $1) }, page: page,
      finished: finished)
  }

  /// open PR 一覧。ページの渡し方と終わり方は `openIssues` と同じ。
  func openPullRequests(
    repo: GitHubRepoName, page: @escaping ([GitHubOpenItem]) -> Void,
    finished: @escaping (Bool) -> Void
  ) {
    fetchPages(
      limit: Self.openPullRequestLimit,
      arguments: { Self.openPullRequestsPageArguments(repo: repo, first: $0, after: $1) },
      page: page, finished: finished)
  }

  /// Issue・PR に共通する欄。
  private static let openItemFields =
    "__typename number title updatedAt author{login} assignees(first:10){nodes{login}}"

  /// open issue 一覧の 1 ページの問い合わせ引数。`after` は前のページの `endCursor`（初回は nil）。
  static func openIssuesPageArguments(repo: GitHubRepoName, first: Int, after: String?)
    -> [String]
  {
    openListPageArguments(
      repo: repo, connection: "issues", fields: openItemFields, first: first, after: after)
  }

  /// open PR 一覧の 1 ページの問い合わせ引数。
  static func openPullRequestsPageArguments(repo: GitHubRepoName, first: Int, after: String?)
    -> [String]
  {
    openListPageArguments(
      repo: repo, connection: "pullRequests",
      fields: openItemFields + " isDraft reviewDecision "
        + "commits(last:1){nodes{commit{statusCheckRollup{state}}}} "
        + "reviewRequests(first:20){nodes{requestedReviewer{"
        + "__typename ...on User{login} ...on Team{slug organization{login}}}}}",
      first: first, after: after)
  }

  /// ページの位置（カーソル）はアプリが持ち、1 ページ＝1 回の gh 呼び出しにする——`--paginate` に
  /// 任せると 1 回の呼び出しが上限までの全ページになり、`timeout` がページ単位で効かなくなる。
  /// owner と name は `-f`（文字列のまま）で渡す（`resolveRepositoryArguments` と同じく、数字だけの名前を
  /// 整数に変えないため）。並びは作成の新しい順——更新の順では、取っている間に更新された項目がページを
  /// またいで動き、重複や取りこぼしが出る（更新の順への並べ直しは表示がする）。
  private static func openListPageArguments(
    repo: GitHubRepoName, connection: String, fields: String, first: Int, after: String?
  ) -> [String] {
    let query = """
      query($owner:String!,$name:String!,$first:Int!,$endCursor:String){\
      repository(owner:$owner,name:$name){\
      \(connection)(states:OPEN,first:$first,after:$endCursor,\
      orderBy:{field:CREATED_AT,direction:DESC}){\
      nodes{\(fields)} pageInfo{hasNextPage endCursor}}}}
      """
    var args = [
      "api", "graphql", "--hostname", "github.com", "-f", "query=\(query)", "-f",
      "owner=\(repo.owner)", "-f", "name=\(repo.name)", "-F", "first=\(first)",
    ]
    if let after { args += ["-f", "endCursor=\(after)"] }
    return args + ["--jq", ".data.repository.\(connection) | {nodes, pageInfo}"]
  }

  /// レビュー依頼の検索で取る上限（ページ送りしない）。
  static let reviewRequestLimit = 100

  /// 自分の login と、`repo` の open な PR のうち自分（自分の所属チームを含む）にレビューを頼んでいるものの
  /// 番号を、1 回の問い合わせで取る。チームの所属（入れ子を含む）の判定は GitHub の検索
  /// `review-requested:@me` に任せる。失敗は nil。メインで返る。
  func reviewRequests(
    repo: GitHubRepoName, completion: @escaping (GitHubReviewRequests?) -> Void
  ) {
    queue.async {
      let response: ReviewRequestsResponse? = self.resolveGh().flatMap {
        self.fetchSync($0, Self.reviewRequestsArguments(repo), cwd: NSHomeDirectory())
      }
      let result = response?.data.map { data in
        GitHubReviewRequests(
          login: data.viewer.login, numbers: Set(data.search.nodes.compactMap { $0?.number }))
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  static func reviewRequestsArguments(_ repo: GitHubRepoName) -> [String] {
    [
      "api", "graphql", "--hostname", "github.com", "-f",
      "query=query($q:String!){viewer{login} "
        + "search(query:$q,type:ISSUE,first:\(reviewRequestLimit)){nodes{...on PullRequest{number}}}}",
      "-f", "q=repo:\(repo.value) is:pr is:open review-requested:@me",
    ]
  }

  /// 自分（`login`）を項目の担当者かレビュアーに足し、応答の担当者・個人宛のレビュー依頼の login を返す
  /// （nil = 失敗）。成否は呼び出し側が、返った列に自分が入っているかで決める——GitHub は push 権限の
  /// 無い担当者を黙って捨てて成功を返す。メインで返る。
  func addSelf(
    as role: GitHubSelfRole, to item: GitHubItemID, login: String,
    completion: @escaping ([String]?) -> Void
  ) {
    queue.async {
      let result: [String]? = self.resolveGh().flatMap { gh in
        let args = Self.addSelfArguments(as: role, to: item, login: login)
        switch role {
        case .assignee:
          let response: AssigneesResponse? = self.fetchSync(gh, args, cwd: NSHomeDirectory())
          return response?.assignees.map(\.login)
        case .reviewer:
          let response: ReviewersResponse? = self.fetchSync(gh, args, cwd: NSHomeDirectory())
          return response?.requestedReviewers.map(\.login)
        }
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  /// 書き込みの引数（REST）。担当者は Issue も PR も同じ issues の口。`gh issue edit` / `gh pr edit` を
  /// 使わないのは、`--add-reviewer` が `@me` を受けず、権限の無い担当者の黙った無視が終了コードに出ないため。
  static func addSelfArguments(as role: GitHubSelfRole, to item: GitHubItemID, login: String)
    -> [String]
  {
    let path =
      switch role {
      case .assignee: "repos/\(item.repo.value)/issues/\(item.number)/assignees"
      case .reviewer: "repos/\(item.repo.value)/pulls/\(item.number)/requested_reviewers"
      }
    let field = role == .assignee ? "assignees[]" : "reviewers[]"
    return ["api", "--hostname", "github.com", "-X", "POST", path, "-f", "\(field)=\(login)"]
  }

  /// ページの列を回す。次のページがあり、件数が上限未満の間だけ続け、最後のページは残り件数だけ頼む。
  /// `page` と `finished` はメインへ届いた順に載せる（メインキューへの async は順序を保つ）。
  private func fetchPages<T: Decodable>(
    limit: Int, arguments: @escaping (Int, String?) -> [String],
    page: @escaping ([T]) -> Void, finished: @escaping (Bool) -> Void
  ) {
    queue.async {
      guard let gh = self.resolveGh() else {
        DispatchQueue.main.async { finished(false) }
        return
      }
      var fetched = 0
      var cursor: String?
      while true {
        let first = min(Self.openListPageSize, limit - fetched)
        guard
          let result: GitHubPage<T> = self.fetchSync(
            gh, arguments(first, cursor), cwd: NSHomeDirectory())
        else {
          DispatchQueue.main.async { finished(false) }
          return
        }
        fetched += result.nodes.count
        DispatchQueue.main.async { page(result.nodes) }
        guard result.pageInfo.hasNextPage, !result.nodes.isEmpty, fetched < limit,
          let next = result.pageInfo.endCursor
        else { break }
        cursor = next
      }
      DispatchQueue.main.async { finished(true) }
    }
  }
}

/// `gh repo view --json nameWithOwner,url` の出力。
private struct DefaultRepositoryResponse: Decodable {
  let nameWithOwner: String
  /// リポジトリのページ。ホストを確かめる。
  let url: String
}

/// 自分の login とレビュー依頼の検索の出力。
private struct ReviewRequestsResponse: Decodable {
  let data: ReviewRequestsData?
}

private struct ReviewRequestsData: Decodable {
  struct Search: Decodable { let nodes: [SearchNode?] }
  let viewer: UserLogin
  let search: Search
}

/// PR でない結果は `{}` で届くので、番号は無いことがある。
private struct SearchNode: Decodable {
  let number: Int?
}

private struct UserLogin: Decodable {
  let login: String
}

/// 担当者を足した応答（Issue）。
private struct AssigneesResponse: Decodable {
  let assignees: [UserLogin]
}

/// レビュアーを足した応答（PR）。
private struct ReviewersResponse: Decodable {
  enum CodingKeys: String, CodingKey { case requestedReviewers = "requested_reviewers" }
  let requestedReviewers: [UserLogin]
}

/// 開いた workspace の GitHub のリポジトリを決められない理由。
enum GitHubRepositoryUnavailable: Error, Equatable {
  case ghMissing, ghUnauthed
  /// gh が既定のリポジトリを返さなかった（GitHub のリポジトリが無い・オフライン）。
  case notFound
}

/// 自分の login と、自分（所属チームを含む）にレビューを頼んでいる open な PR の番号。
struct GitHubReviewRequests: Equatable {
  let login: String
  let numbers: Set<Int>
}

/// 項目に自分を足すときの役割。
enum GitHubSelfRole: Equatable {
  case assignee, reviewer
}
