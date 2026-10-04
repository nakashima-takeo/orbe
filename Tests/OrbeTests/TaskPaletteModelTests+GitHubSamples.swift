import Foundation

@testable import Orbe

/// GitHub タブの題材: root が `o/n` に解決済みで、一覧を取り終えた置き場。自分は `me`。
extension TaskPaletteModelTests {
  static let gitHubRepo = GitHubRepoName(nameWithOwner: "o/n")

  /// 自分を足す書き込みを溜め、テストが応答を着地させる。open 一覧の取り直しも溜める。
  final class GitHubTabSource {
    private(set) var writes: [GitHubTabWrite] = []
    private(set) var fetches: [(kind: GitHubItemKind, finish: ([GitHubOpenItem]) -> Void)] = []

    var source: GitHubOpenLists.Source {
      GitHubOpenLists.Source(
        defaultRepository: { _, completion in completion(.success(gitHubRepo)) },
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
          self.writes.append(GitHubTabWrite(role: role, item: item, completion: completion))
        })
    }
  }

  func gid(_ number: Int) -> GitHubItemID { GitHubItemID(repo: "o/n", number: number)! }

  /// 更新日時は番号の新しさに合わせる（番号の大きい項目ほど上に並ぶ）。
  func openIssue(
    _ number: Int, _ title: String? = nil, author: String = "someone", assignees: [String] = []
  ) -> GitHubOpenItem {
    GitHubOpenItem(
      number: number, title: title ?? "issue \(number)",
      updatedAt: Date(timeIntervalSince1970: TimeInterval(number)), author: author,
      assignees: assignees, pullRequest: nil)
  }

  func openPullRequest(_ number: Int, teams: [String] = []) -> GitHubOpenItem {
    GitHubOpenItem(
      number: number, title: "pr \(number)",
      updatedAt: Date(timeIntervalSince1970: TimeInterval(number)), author: "someone",
      assignees: [],
      pullRequest: .init(isDraft: false, review: nil, checks: nil, reviewers: [], teams: teams))
  }

  /// root が `o/n` に解決済みで、一覧を取り終えた置き場で開き、GitHub タブを見ている画面。自分は `me`。
  func gitHubModel(
    _ tasks: [TaskItem], issues: [GitHubOpenItem] = [], pullRequests: [GitHubOpenItem] = [],
    reviewRequests: Set<Int> = [], source: GitHubTabSource = GitHubTabSource()
  ) -> TaskPaletteModel {
    var repository = GitHubOpenLists.Repository()
    repository.issues.items = issues
    repository.pullRequests.items = pullRequests
    repository.reviewRequests = reviewRequests
    let viewer = GitHubViewer(login: "me")
    let lists = openLists(
      [TaskPaletteSamples.root: .init(resolution: .resolved, repo: Self.gitHubRepo)],
      [Self.gitHubRepo: repository], source: source, viewer: viewer)
    let palette = TaskPaletteSamples.model(
      tasks, githubItems: GitHubItemCache(viewer: viewer, fetch: { _, _ in }), openLists: lists)
    palette.toggleTab()
    return palette
  }

  func openLists(
    _ roots: [String: GitHubOpenLists.Root],
    _ repositories: [GitHubRepoName: GitHubOpenLists.Repository],
    source: GitHubTabSource = GitHubTabSource(), viewer: GitHubViewer = GitHubViewer()
  ) -> GitHubOpenLists {
    GitHubOpenLists(roots: roots, repositories: repositories, source: source.source, viewer: viewer)
  }

  func issueLink(_ number: Int) -> TaskLink { TaskLink(item: gid(number), kind: .issue) }

}

/// 撃たれた「自分を足す」書き込み 1 本（応答の login の列を返す口）。
struct GitHubTabWrite {
  let role: GitHubSelfRole
  let item: GitHubItemID
  let completion: ([String]?) -> Void
}
