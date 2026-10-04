import Foundation

@testable import Orbe

/// GitHub タブのテストの題材: root（`TaskPaletteSamples.root`）が `o/n` に解決済みで、一覧を取り終えた
/// 置き場。自分は `me`。
@MainActor
enum TaskPaletteGitHubSamples {
  static let repo = GitHubRepoName(nameWithOwner: "o/n")

  /// 自分を足す書き込みを溜め、テストが応答を着地させる。open 一覧の取り直しも溜める。
  final class Source {
    private(set) var writes: [TaskPaletteGitHubWrite] = []
    private(set) var fetches: [(kind: GitHubItemKind, finish: ([GitHubOpenItem]) -> Void)] = []

    var source: GitHubOpenLists.Source {
      GitHubOpenLists.Source(
        defaultRepository: { _, completion in completion(.success(repo)) },
        openItems: { _, kind, page, finished in
          self.fetches.append(
            (
              kind,
              { items in
                page(items)
                finished(true)
              }
            ))
        },
        reviewRequests: { _, _ in },
        addSelf: { role, item, _, completion in
          self.writes.append(TaskPaletteGitHubWrite(role: role, item: item, completion: completion))
        })
    }
  }

  static func id(_ number: Int) -> GitHubItemID { GitHubItemID(repo: "o/n", number: number)! }

  /// 更新日時は番号の新しさに合わせる（番号の大きい項目ほど上に並ぶ）。
  static func issue(
    _ number: Int, _ title: String? = nil, author: String = "someone", assignees: [String] = []
  ) -> GitHubOpenItem {
    GitHubOpenItem(
      number: number, title: title ?? "issue \(number)",
      updatedAt: Date(timeIntervalSince1970: TimeInterval(number)), author: author,
      assignees: assignees, pullRequest: nil)
  }

  static func pullRequest(_ number: Int, teams: [String] = []) -> GitHubOpenItem {
    GitHubOpenItem(
      number: number, title: "pr \(number)",
      updatedAt: Date(timeIntervalSince1970: TimeInterval(number)), author: "someone",
      assignees: [],
      pullRequest: .init(isDraft: false, review: nil, checks: nil, reviewers: [], teams: teams))
  }

  /// root が `o/n` に解決済みで、一覧を取り終えた置き場で開き、GitHub タブを見ている画面。自分は `me`。
  static func model(
    _ tasks: [TaskItem], issues: [GitHubOpenItem] = [], pullRequests: [GitHubOpenItem] = [],
    reviewRequests: Set<Int> = [], source: Source = Source()
  ) -> TaskPaletteModel {
    var repository = GitHubOpenLists.Repository()
    repository.issues.items = issues
    repository.pullRequests.items = pullRequests
    repository.reviewRequests = reviewRequests
    let viewer = GitHubViewer(login: "me")
    let lists = lists(
      [TaskPaletteSamples.root: .init(resolution: .resolved, repo: repo)],
      [repo: repository], source: source, viewer: viewer)
    let palette = TaskPaletteSamples.model(
      tasks, githubItems: GitHubItemCache(viewer: viewer, fetch: { _, _ in }), openLists: lists)
    palette.toggleTab()
    return palette
  }

  static func lists(
    _ roots: [String: GitHubOpenLists.Root],
    _ repositories: [GitHubRepoName: GitHubOpenLists.Repository],
    source: Source = Source(), viewer: GitHubViewer = GitHubViewer()
  ) -> GitHubOpenLists {
    GitHubOpenLists(roots: roots, repositories: repositories, source: source.source, viewer: viewer)
  }

  static func link(_ number: Int) -> TaskLink { TaskLink(item: id(number), kind: .issue) }
}

/// 撃たれた「自分を足す」書き込み 1 本（応答の login の列を返す口）。
struct TaskPaletteGitHubWrite {
  let role: GitHubSelfRole
  let item: GitHubItemID
  let completion: ([String]?) -> Void
}
