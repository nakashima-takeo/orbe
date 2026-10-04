import Foundation

/// GitHub の Issue か PR を 1 つ指す同一性。Issue と PR は 1 つのリポジトリの中で番号の空間を共有するので、
/// 同じリポジトリの同じ番号は同じ項目であり、等値はリポジトリと番号だけで決まる（種別を含めない）。
struct GitHubItemID: Hashable {
  let repo: GitHubRepoName
  let number: Int

  /// `repo` は `owner/name`（各段は英数字・`-`・`_`・`.` で空でない）、`number` は 1 以上だけを受ける。
  init?(repo: String, number: Int) {
    let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, number >= 1,
      parts.allSatisfy({ part in
        !part.isEmpty
          && part.unicodeScalars.allSatisfy {
            $0.isASCII
              && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0))
          }
      })
    else { return nil }
    self.repo = GitHubRepoName(nameWithOwner: repo)
    self.number = number
  }

  /// `owner/name#221`。
  var text: String { "\(repo.value)#\(number)" }

  /// owner を除いたリポジトリの名前。
  var repoName: String { String(repo.value.split(separator: "/").last ?? "") }
}

/// Issue か PR か。
enum GitHubItemKind: String, Codable, Equatable {
  case issue
  case pr
}

/// GitHub から取った 1 項目の値。
struct GitHubItemSummary: Equatable {
  enum State: Equatable {
    case open, closed, merged
  }

  /// PR のレビュー状態（GraphQL の `reviewDecision`）。
  enum ReviewDecision: String, Equatable {
    case reviewRequired = "REVIEW_REQUIRED"
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
  }

  /// 最後のコミットの CI の集約状態。
  enum Checks: Equatable {
    case success, failure, pending
  }

  /// PR だけが持つ値。
  struct PullRequest: Equatable {
    let isDraft: Bool
    let review: ReviewDecision?
    let checks: Checks?
    /// 作成者の login。
    let author: String?
  }

  /// PR の状態を 1 語で言うときの語。強いものを先に取る（マージ済み > 閉じた > 下書き > レビュー状態）。
  enum PullRequestPhase: Equatable {
    case merged, closed, draft, reviewRequired, approved, changesRequested
  }

  let title: String
  let state: State
  /// PR なら値がある。nil は Issue。
  let pullRequest: PullRequest?

  /// GitHub 上の実体の種別。
  var kind: GitHubItemKind { pullRequest == nil ? .issue : .pr }

  /// PR でなければ nil。レビュー状態が無い open の PR も nil。
  var pullRequestPhase: PullRequestPhase? {
    guard let pullRequest else { return nil }
    switch state {
    case .merged: return .merged
    case .closed: return .closed
    case .open:
      if pullRequest.isDraft { return .draft }
      switch pullRequest.review {
      case .reviewRequired: return .reviewRequired
      case .approved: return .approved
      case .changesRequested: return .changesRequested
      case nil: return nil
      }
    }
  }
}

/// 1 項目を問い合わせた答え。
enum GitHubItemAnswer: Equatable {
  case found(GitHubItemSummary)
  /// 問い合わせたが、無かった（存在しない・見えない private を区別しない）。
  case missing
}

/// 1 回の問い合わせで届いた答え。
struct GitHubItemsBatch: Equatable {
  let viewerLogin: String?
  let answers: [GitHubItemID: GitHubItemAnswer]
}

/// 結び付いた項目を番号で直接まとめて問い合わせる GraphQL の、引数と出力の読み取り。リポジトリごとの別名
/// （`r0`）の下に項目ごとの別名（`n221`）を並べ、`issueOrPullRequest` で種別に依らず引く。
enum GitHubItemQuery {
  /// 項目 1 つの欄。`__typename` で Issue と PR の欄を分ける。
  private static let itemFields =
    "__typename ...on Issue{title state} ...on PullRequest{title state isDraft reviewDecision "
    + "author{login} commits(last:1){nodes{commit{statusCheckRollup{state}}}}}"

  /// 問い合わせの引数。owner と name は `-f`（文字列のまま）で渡す（`resolveRepositoryArguments` と同じく、
  /// 数字だけの名前を整数に変えないため）。番号は検証済みの整数なので問い合わせに直接書く。
  static func arguments(_ ids: [GitHubItemID]) -> [String] {
    var declarations: [String] = []
    var fields = ["viewer{login}"]
    var variables: [String] = []
    for (index, group) in repositories(ids).enumerated() {
      declarations.append("$o\(index):String!,$n\(index):String!")
      let items = group.numbers.map { "n\($0):issueOrPullRequest(number:\($0)){\(itemFields)}" }
      fields.append(
        "r\(index):repository(owner:$o\(index),name:$n\(index)){\(items.joined(separator: " "))}")
      variables += ["-f", "o\(index)=\(group.owner)", "-f", "n\(index)=\(group.name)"]
    }
    let query =
      "query(\(declarations.joined(separator: ","))){\(fields.joined(separator: " "))}"
    return ["api", "graphql", "--hostname", "github.com", "-f", "query=\(query)"] + variables
  }

  /// 出力を読む。gh は項目の一部が見つからない（`NOT_FOUND`）だけで非 0 で終わるので、終了コードでなく
  /// JSON の `data` で見分ける。`data` が無ければその回の失敗（nil）。別名が null の項目と、リポジトリが
  /// null の項目は「無かった」。
  static func batch(from stdout: Data, ids: [GitHubItemID]) -> GitHubItemsBatch? {
    guard let response = try? JSONDecoder().decode(ItemsResponse.self, from: stdout),
      let data = response.data
    else { return nil }
    var answers: [GitHubItemID: GitHubItemAnswer] = [:]
    for (index, group) in repositories(ids).enumerated() {
      let nodes = data.repositories["r\(index)"] ?? nil
      for number in group.numbers {
        guard let id = GitHubItemID(repo: group.repo.value, number: number) else { continue }
        let summary = (nodes?["n\(number)"] ?? nil)?.summary
        answers[id] = summary.map(GitHubItemAnswer.found) ?? .missing
      }
    }
    return GitHubItemsBatch(viewerLogin: data.viewer?.login, answers: answers)
  }

  private struct RepositoryGroup {
    let repo: GitHubRepoName
    var numbers: [Int]
    var owner: String { String(repo.value.split(separator: "/").first ?? "") }
    var name: String { String(repo.value.split(separator: "/").last ?? "") }
  }

  /// リポジトリごとにまとめる（現れた順）。引数と読み取りが同じ別名を引くための、唯一の並び。
  private static func repositories(_ ids: [GitHubItemID]) -> [RepositoryGroup] {
    var groups: [RepositoryGroup] = []
    for id in ids {
      if let index = groups.firstIndex(where: { $0.repo == id.repo }) {
        if !groups[index].numbers.contains(id.number) { groups[index].numbers.append(id.number) }
      } else {
        groups.append(RepositoryGroup(repo: id.repo, numbers: [id.number]))
      }
    }
    return groups
  }
}

private struct ItemsResponse: Decodable {
  let data: ItemsData?
}

/// `data`。`viewer` のほかは、リポジトリの別名 → 項目の別名 → 項目（どちらも null がありうる）。
private struct ItemsData: Decodable {
  struct Viewer: Decodable { let login: String? }

  struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  let viewer: Viewer?
  let repositories: [String: [String: ItemNode?]?]

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    viewer = try c.decodeIfPresent(Viewer.self, forKey: Key(stringValue: "viewer"))
    var repositories: [String: [String: ItemNode?]?] = [:]
    for key in c.allKeys where key.stringValue != "viewer" {
      repositories[key.stringValue] = try c.decode([String: ItemNode?]?.self, forKey: key)
    }
    self.repositories = repositories
  }
}

/// `issueOrPullRequest` の 1 項目。
private struct ItemNode: Decodable {
  struct Author: Decodable { let login: String? }
  enum CodingKeys: String, CodingKey {
    case typename = "__typename"
    case title, state, isDraft, reviewDecision, author, commits
  }

  let typename: String
  let title: String?
  let state: String?
  let isDraft: Bool?
  let reviewDecision: String?
  let author: Author?
  let commits: ItemCommits?

  /// 読めない種別・状態は nil（「無かった」と同じに扱う）。
  var summary: GitHubItemSummary? {
    guard let title, let state else { return nil }
    switch (typename, state) {
    case ("Issue", "OPEN"): return GitHubItemSummary(title: title, state: .open, pullRequest: nil)
    case ("Issue", "CLOSED"):
      return GitHubItemSummary(title: title, state: .closed, pullRequest: nil)
    case ("PullRequest", _):
      let states: [String: GitHubItemSummary.State] = [
        "OPEN": .open, "CLOSED": .closed, "MERGED": .merged,
      ]
      guard let prState = states[state] else { return nil }
      return GitHubItemSummary(
        title: title, state: prState,
        pullRequest: GitHubItemSummary.PullRequest(
          isDraft: isDraft ?? false,
          review: reviewDecision.flatMap(GitHubItemSummary.ReviewDecision.init(rawValue:)),
          checks: checks, author: author?.login))
    default:
      return nil
    }
  }

  private var checks: GitHubItemSummary.Checks? {
    switch commits?.nodes?.last??.commit.statusCheckRollup?.state {
    case "SUCCESS": .success
    case "FAILURE", "ERROR": .failure
    case "PENDING", "EXPECTED": .pending
    default: nil
    }
  }
}

/// `commits(last:1){nodes{commit{statusCheckRollup{state}}}}`。
private struct ItemCommits: Decodable {
  let nodes: [ItemCommitNode?]?
}

private struct ItemCommitNode: Decodable {
  struct Commit: Decodable { let statusCheckRollup: ItemCheckRollup? }
  let commit: Commit
}

private struct ItemCheckRollup: Decodable {
  let state: String
}
