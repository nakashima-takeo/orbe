import Foundation

@testable import Orbe

/// タスク画面のテストの題材。今日は `DesignSceneFixtures.taskToday`（2025-10-04）に固定し、ストアは
/// 本物の `TaskStore` を渡す（保存先は隔離ハーネスが per-test に向ける）。
@MainActor
enum TaskPaletteSamples {
  static let opened = TaskPaletteWorkspaces.Entry(id: UUID(), name: "orbe")
  static let other = TaskPaletteWorkspaces.Entry(id: UUID(), name: "web-app")
  /// 開いた workspace の root。
  static let root = "/work/orbe"

  static func task(
    _ id: Int, _ title: String, _ status: TaskItem.Status = .todo,
    _ mutate: (inout TaskItem) -> Void = { _ in }
  ) -> TaskItem {
    var item = TaskItem(
      id: id, title: title, status: status, waiting: nil, priority: .medium, due: nil,
      workspace: nil, description: "", createdAt: DesignSceneFixtures.taskToday, createdBy: nil)
    mutate(&item)
    return item
  }

  /// `tasks` の列で開いたタスク画面。開いた workspace は `opened`、サイドバーの順は `opened`・`other`。
  /// GitHub の値の置き場は、既定では何も取りに行かない。
  static func model(
    _ tasks: [TaskItem], githubItems: GitHubItemCache = GitHubItemCache(fetch: { _, _ in }),
    openLists: GitHubOpenLists? = nil, agents: WorktreeAgentActivity = WorktreeAgentActivity()
  ) -> TaskPaletteModel {
    let file = TasksFile(
      version: TaskPersistence.version, nextId: (tasks.map(\.id).max() ?? 0) + 1, tasks: tasks)
    return TaskPaletteModel(
      store: TaskStore(file: file), githubItems: githubItems, viewer: githubItems.viewer,
      openLists: openLists ?? GitHubOpenLists(source: .idle, viewer: githubItems.viewer),
      root: root, agents: agents,
      workspaces: TaskPaletteWorkspaces(opened: opened, all: [opened, other]),
      now: DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone)
  }

  static func link(_ kind: GitHubItemKind, _ number: Int, repo: String = "o/n") -> TaskLink {
    TaskLink(item: GitHubItemID(repo: repo, number: number)!, kind: kind)
  }

  /// 未着手 3 件（1 a・2 b・3 c）。
  static func threeTodos() -> TaskPaletteModel {
    model([task(1, "a"), task(2, "b"), task(3, "c")])
  }
}

extension GitHubOpenLists.Source {
  /// 何も問い合わせない・書かない（答えは返らない）。
  static var idle: Self {
    Self(
      defaultRepository: { _, _ in }, openItems: { _, _, _, _ in }, reviewRequests: { _, _ in },
      addSelf: { _, _, _, _ in })
  }
}
