import Foundation

/// PR のレビューのやりとりの読み取りと書き込み。問い合わせ先はリポジトリ名と node ID で決まるので、作業ディレクトリは
/// リポジトリに依らない。どれもメインスレッドで返る。
extension GitHubCLI {
  /// PR 1 件のレビューのやりとりを、一時点のものとして揃えて読む。スレッドは全件をページングして読む。ページの間に push が
  /// 入ったら（PR の先頭のコミットが 1 ページ目と違えば）、最初から読み直す。読み直しは 1 回までで、なお違えば失敗（理由は
  /// 空）。途中のページの失敗は全体の失敗。
  func pullRequestReview(
    _ id: GitHubItemID,
    completion: @escaping (Result<GitHubPullRequestReview, GitHubFailure>) -> Void
  ) {
    queue.async {
      let result: Result<GitHubPullRequestReview, GitHubFailure> =
        self.resolveGh().map { gh in
          for _ in 0..<2 {
            switch ReviewRead(cli: self, gh: gh, id: id).read() {
            case .read(let review): return .success(review)
            case .failed(let failure): return .failure(failure)
            case .moved: continue
            }
          }
          return .failure(.reason(""))
        } ?? .failure(.reason(""))
      DispatchQueue.main.async { completion(result) }
    }
  }

  /// レビューへの書き込み 1 つを、PR `nodeID` に送る。`pendingReview` は送る前に分かっている自分の未送信のレビュー。
  /// `reviewedCommit` は、利用者が見ていたレビューのやりとりを読んだ時点の PR の先頭のコミット。書き込みが何回の呼び出しに
  /// なるかは `GitHubReviewWriting` が決める。
  func writeReview(
    _ write: GitHubReviewWrite, pullRequest nodeID: String, pendingReview: String?,
    reviewedCommit: String, completion: @escaping (GitHubReviewWriteResult) -> Void
  ) {
    queue.async {
      let result =
        self.resolveGh().map { gh in
          GitHubReviewWriting(
            cli: self, gh: gh, pullRequest: nodeID, pendingReview: pendingReview,
            reviewedCommit: reviewedCommit
          ).write(write)
        } ?? GitHubReviewWriteResult(pendingReview: pendingReview, failure: .reason(""))
      DispatchQueue.main.async { completion(result) }
    }
  }
}

/// レビューへの書き込み。どれも未送信のレビューに積む（解決と、その取り消しと、レビューの送信を除く）。
enum GitHubReviewWrite: Equatable {
  /// 行の範囲 `lines` に新しいスレッドを付ける。`commit` は、行の番号を数えた diff の PR の先頭のコミット。未送信のレビューが
  /// 無ければ、作るレビューをこのコミットに結ぶ。在れば使わない（足すスレッドの入力にコミットの欄が無く、行は GitHub が
  /// 決めるコミットの diff の行として読まれる）。
  case addThread(path: String, lines: GitHubLineRange, commit: String, body: String)
  /// スレッドに返信する。`resolve` なら、返信が通った後にスレッドを解決する。
  case reply(thread: String, body: String, resolve: Bool)
  /// スレッドを解決する（偽なら解決を取り消す）。
  case setResolved(thread: String, Bool)
  /// レビューを送信する（未送信のコメントがあれば、まとめて公開する）。`body` が空なら全体へのコメントを付けない。
  /// 未送信のレビューが無ければ、作って送るレビューを、レビューのやりとりを読んだ時点の先頭のコミットに結ぶ（承認を、
  /// 利用者が見ていないコミットに付けない）。在れば、送信の入力にコミットの欄が無いので結ばない。
  case submit(GitHubReviewEvent, body: String)
}

/// レビューへの書き込みの結果。
struct GitHubReviewWriteResult: Equatable {
  /// 書き込みの後の自分の未送信のレビュー（分かった限り。送信が通れば nil）。
  let pendingReview: String?
  /// 通らなかった呼び出しがあれば、その失敗の種類。失敗した呼び出しより後の呼び出しは送らない。
  let failure: GitHubFailure?
  /// 返信の呼び出しが通ったか（「解決して返信」で、解決だけが通らなかったときも真）。
  let replied: Bool

  init(pendingReview: String?, failure: GitHubFailure?, replied: Bool = false) {
    self.pendingReview = pendingReview
    self.failure = failure
    self.replied = replied
  }
}

/// 書き込み 1 つを、GraphQL の mutation の呼び出しに分けて順に送る。未送信のレビューがあればその ID を名指しする。無いときの
/// スレッドの追加は、レビューの作成と最初のスレッドを 1 回の呼び出しで送る（スレッドが通らなければ、空の未送信のレビューを
/// GitHub に残さない）。無いときの返信は、レビューを作ってから返信する。
struct GitHubReviewWriting {
  let cli: GitHubCLI
  let gh: String
  let pullRequest: String
  let pendingReview: String?
  let reviewedCommit: String

  func write(_ write: GitHubReviewWrite) -> GitHubReviewWriteResult {
    switch write {
    case .addThread(let path, let lines, let commit, let body):
      let thread = GitHubReviewMutation.Thread(path: path, lines: lines, body: body)
      guard let review = pendingReview else {
        return finish(
          send(.createReview(pullRequest: pullRequest, commit: commit, thread: thread)).map { $0 },
          else: nil)
      }
      return finish(send(.addThread(review: review, thread)).map { _ in review }, else: review)
    case .reply(let thread, let body, let resolve):
      let review: String
      if let pendingReview {
        review = pendingReview
      } else {
        switch send(.createReview(pullRequest: pullRequest, commit: reviewedCommit, thread: nil)) {
        case .failure(let failure):
          return GitHubReviewWriteResult(pendingReview: nil, failure: failure)
        case .success(let created): review = created
        }
      }
      if case .failure(let failure) = send(.reply(thread: thread, review: review, body: body)) {
        return GitHubReviewWriteResult(pendingReview: review, failure: failure)
      }
      guard resolve else {
        return GitHubReviewWriteResult(pendingReview: review, failure: nil, replied: true)
      }
      let resolved = finish(
        send(.setResolved(thread: thread, true)).map { _ in review }, else: review)
      return GitHubReviewWriteResult(
        pendingReview: resolved.pendingReview, failure: resolved.failure, replied: true)
    case .setResolved(let thread, let resolved):
      return finish(
        send(.setResolved(thread: thread, resolved)).map { _ in pendingReview },
        else: pendingReview)
    case .submit(let event, let body):
      let mutation: GitHubReviewMutation =
        if let review = pendingReview {
          .submit(review: review, event: event, body: body)
        } else {
          .submitNew(pullRequest: pullRequest, commit: reviewedCommit, event: event, body: body)
        }
      return finish(send(mutation).map { _ in nil }, else: pendingReview)
    }
  }

  /// 通れば、その後の未送信のレビュー。通らなければ `fallback`（送る前に分かっていたもの）。
  private func finish(
    _ sent: Result<String?, GitHubFailure>, else fallback: String?
  ) -> GitHubReviewWriteResult {
    switch sent {
    case .success(let review): GitHubReviewWriteResult(pendingReview: review, failure: nil)
    case .failure(let failure): GitHubReviewWriteResult(pendingReview: fallback, failure: failure)
    }
  }

  /// mutation を 1 回送り、レスポンスに載った ID を返す。クエリと変数は 1 つの JSON にまとめて標準入力で渡す——本文を argv に
  /// 載せない（プロセスの一覧から見えない）。値の型は JSON が持つので、値ごとに `-f`（文字列のまま）と `-F`（`@` で始まる値を
  /// ファイルとして読み、`true`・`null`・数字を読み替える）を選び分けずに済む。
  private func send(_ mutation: GitHubReviewMutation) -> Result<String, GitHubFailure> {
    guard let input = try? mutation.requestBody() else { return .failure(.reason("")) }
    let out = cli.runSync(
      gh, GitHubReviewMutation.arguments, cwd: NSHomeDirectory(), call: .write, stdin: input)
    if let failure = out.failure { return .failure(failure) }
    guard let id = GitHubReviewMutation.writtenID(from: out.stdout) else {
      return .failure(.reason(""))
    }
    return .success(id)
  }
}

/// レビューの mutation 1 回分。レスポンスは、エイリアス `m` の下にある値 1 つの `id` だけを読む（通ったかと、作ったものの ID）。
enum GitHubReviewMutation {
  struct Thread {
    let path: String
    let lines: GitHubLineRange
    let body: String
  }

  /// 未送信のレビューを作り、レビューをコミット `commit`（利用者が見ていた先頭）に結ぶ（`thread` があれば、最初のスレッドも
  /// 1 回で付ける。スレッドの行は、そのコミットの diff の行として読まれる）。送信の `event` は渡さない（渡すと作った時点で
  /// 送信になる）。
  case createReview(pullRequest: String, commit: String, thread: Thread?)
  case addThread(review: String, Thread)
  case reply(thread: String, review: String, body: String)
  case setResolved(thread: String, Bool)
  case submit(review: String, event: GitHubReviewEvent, body: String)
  /// 未送信のレビューが無いときの送信（作って、すぐ送る）。レビューを `commit` に結ぶ。
  case submitNew(pullRequest: String, commit: String, event: GitHubReviewEvent, body: String)

  /// どの mutation も同じ引数で、リクエストの本文は標準入力から読ませる。
  static let arguments = ["api", "graphql", "--hostname", "github.com", "--input", "-"]

  /// GraphQL のリクエストの本文（`{"query":…,"variables":…}`）。
  func requestBody() throws -> Data {
    let (query, variables) = request
    return try JSONEncoder().encode(Request(query: query, variables: variables))
  }

  private var request: (String, [String: Value]) {
    switch self {
    case .createReview(let pullRequest, let commit, let thread):
      var declarations = ["$pr:ID!", "$commit:GitObjectID!"]
      var fields = ["pullRequestId:$pr", "commitOID:$commit"]
      var variables: [String: Value] = ["pr": .string(pullRequest), "commit": .string(commit)]
      if let thread {
        declarations +=
          ["$path:String!", "$line:Int!", "$side:DiffSide!"]
          + Self.startDeclarations(thread) + ["$body:String!"]
        fields.append(
          "threads:[{path:$path,line:$line,side:$side,\(Self.startFields(thread))body:$body}]")
        variables.merge(Self.variables(thread)) { $1 }
      }
      return (
        "mutation(\(declarations.joined(separator: ","))){m:addPullRequestReview(input:{"
          + "\(fields.joined(separator: ","))}){pullRequestReview{id}}}", variables
      )
    case .addThread(let review, let thread):
      let declarations =
        (["$review:ID!", "$path:String!", "$line:Int!", "$side:DiffSide!"]
        + Self.startDeclarations(thread) + ["$body:String!"]).joined(separator: ",")
      return (
        "mutation(\(declarations))"
          + "{m:addPullRequestReviewThread(input:{pullRequestReviewId:$review,path:$path,"
          + "line:$line,side:$side,\(Self.startFields(thread))body:$body}){thread{id}}}",
        Self.variables(thread).merging(["review": .string(review)]) { $1 }
      )
    case .reply(let thread, let review, let body):
      return (
        "mutation($thread:ID!,$review:ID!,$body:String!){m:addPullRequestReviewThreadReply("
          + "input:{pullRequestReviewThreadId:$thread,pullRequestReviewId:$review,body:$body})"
          + "{comment{id}}}",
        ["thread": .string(thread), "review": .string(review), "body": .string(body)]
      )
    case .setResolved(let thread, let resolved):
      let field = resolved ? "resolveReviewThread" : "unresolveReviewThread"
      return (
        "mutation($thread:ID!){m:\(field)(input:{threadId:$thread}){thread{id}}}",
        ["thread": .string(thread)]
      )
    case .submit(let review, let event, let body):
      return Self.submission(
        "submitPullRequestReview",
        [Input("review", "ID!", "pullRequestReviewId", .string(review))], event: event, body: body)
    case .submitNew(let pullRequest, let commit, let event, let body):
      return Self.submission(
        "addPullRequestReview",
        [
          Input("pr", "ID!", "pullRequestId", .string(pullRequest)),
          Input("commit", "GitObjectID!", "commitOID", .string(commit)),
        ], event: event, body: body)
    }
  }

  /// 送信の mutation。全体へのコメントが空なら、本文の変数を欄ごと省く。
  private static func submission(
    _ field: String, _ inputs: [Input], event: GitHubReviewEvent, body: String
  ) -> (String, [String: Value]) {
    var inputs =
      inputs + [Input("event", "PullRequestReviewEvent!", "event", .string(event.rawValue))]
    if !body.isEmpty { inputs.append(Input("body", "String!", "body", .string(body))) }
    let declarations = inputs.map { "$\($0.variable):\($0.type)" }.joined(separator: ",")
    let fields = inputs.map { "\($0.field):$\($0.variable)" }.joined(separator: ",")
    return (
      "mutation(\(declarations)){m:\(field)(input:{\(fields)}){pullRequestReview{id}}}",
      Dictionary(uniqueKeysWithValues: inputs.map { ($0.variable, $0.value) })
    )
  }

  /// レスポンスの `data.m` に載った値の ID。gh が終了コード 0 で終了しても、`m` が null なら書き込みは通っていない。
  static func writtenID(from stdout: Data) -> String? {
    (try? JSONDecoder().decode(MutationResponse.self, from: stdout))?.data?.m?.values.lazy
      .compactMap { $0?.id }.first
  }

  /// スレッドの変数（行は終わりの行。始まりの行は、範囲のスレッドだけが持つ）。
  private static func variables(_ thread: Thread) -> [String: Value] {
    var variables: [String: Value] = [
      "path": .string(thread.path), "line": .int(thread.lines.end.line),
      "side": .string(thread.lines.end.side.rawValue),
      "body": .string(thread.body),
    ]
    if let start = thread.lines.start {
      variables["startLine"] = .int(start.line)
      variables["startSide"] = .string(start.side.rawValue)
    }
    return variables
  }

  /// 範囲のスレッドの、始まりの行の変数の宣言と入力の欄（1 行のスレッドなら無い）。
  private static func startDeclarations(_ thread: Thread) -> [String] {
    thread.lines.start == nil ? [] : ["$startLine:Int!", "$startSide:DiffSide!"]
  }

  private static func startFields(_ thread: Thread) -> String {
    thread.lines.start == nil ? "" : "startLine:$startLine,startSide:$startSide,"
  }

  /// mutation の入力の欄 1 つと、それに渡す変数。
  private struct Input {
    let variable: String
    let type: String
    let field: String
    let value: Value

    init(_ variable: String, _ type: String, _ field: String, _ value: Value) {
      self.variable = variable
      self.type = type
      self.field = field
      self.value = value
    }
  }

  private struct Request: Encodable {
    let query: String
    let variables: [String: Value]
  }

  /// GraphQL の変数の値。渡さない値は null にせず、変数と入力の欄ごと省く（null を「渡さない」と読むかは公開文書に
  /// 書かれていない）。
  private enum Value: Encodable {
    case string(String)
    case int(Int)

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .string(let text): try container.encode(text)
      case .int(let number): try container.encode(number)
      }
    }
  }
}

/// mutation のレスポンス（`{"data":{"m":{"<値>":{"id":…}}}}`）。
private struct MutationResponse: Decodable {
  struct Payload: Decodable { let m: [String: IdentifiedNode?]? }
  let data: Payload?
}

private struct IdentifiedNode: Decodable { let id: String }

private enum ReviewReading {
  case read(GitHubPullRequestReview)
  case failed(GitHubFailure)
  /// 読んでいる間に、PR の先頭のコミットが動いた。
  case moved
}

/// レビューのやりとりを最初のページから読む 1 回分の処理。
private struct ReviewRead {
  let cli: GitHubCLI
  let gh: String
  let id: GitHubItemID

  func read() -> ReviewReading {
    let first: Result<GitHubReviewQuery.FirstPage, GitHubFailure> = cli.decodeSync(
      gh, GitHubReviewQuery.firstPageArguments(id), cwd: NSHomeDirectory())
    var review: GitHubPullRequestReview
    var pageInfo: GitHubPage<GitHubPullRequestReview.Thread>.PageInfo
    switch first {
    case .failure(let failure): return .failed(failure)
    case .success(let page): (review, pageInfo) = (page.review, page.threads)
    }
    while pageInfo.hasNextPage, let cursor = pageInfo.endCursor {
      let next: Result<GitHubReviewQuery.NextPage, GitHubFailure> = cli.decodeSync(
        gh, GitHubReviewQuery.nextPageArguments(id, after: cursor), cwd: NSHomeDirectory())
      switch next {
      case .failure(let failure): return .failed(failure)
      case .success(let page):
        guard page.headCommit == review.headCommit else { return .moved }
        review.threads += page.threads.nodes
        pageInfo = page.threads.pageInfo
      }
    }
    return .read(review)
  }
}
