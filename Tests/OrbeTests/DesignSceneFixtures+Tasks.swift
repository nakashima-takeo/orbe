import Foundation

@testable import Orbe

/// タスク画面の fixture（見本 XTTasks.png と同じ並び・札）。今日は見本の日付（2025-10-04）に固定し、
/// 待ちの日数と期限の曜日を決定論にする。
extension DesignSceneFixtures {
  static let taskCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return calendar
  }()

  static var taskToday: Date {
    taskCalendar.date(from: DateComponents(year: 2025, month: 10, day: 4, hour: 10))!
  }

  static let taskWorkspaces: TaskPaletteWorkspaces = {
    let ids = (0..<3).map { _ in UUID() }
    let all = zip(ids, ["orbe", "web-app", "api"]).map {
      TaskPaletteWorkspaces.Entry(id: $0, name: $1)
    }
    return TaskPaletteWorkspaces(opened: all[0], all: all)
  }()

  /// 見本の 11 件（進行中 4・未着手 7）と完了 3 件。
  static func taskDesignFile() -> TasksFile {
    let ws = taskWorkspaces.all.map(\.id)
    let daysAgo = { (days: Int) in
      taskCalendar.date(byAdding: .day, value: -days, to: taskToday)!
    }
    func task(
      _ id: Int, _ title: String, _ status: TaskItem.Status = .todo,
      waiting: (String, Int)? = nil, priority: TaskItem.Priority = .medium,
      due: String? = nil, workspace: UUID? = nil, memo: String = "", by: String? = nil,
      links: [TaskLink] = []
    ) -> TaskItem {
      TaskItem(
        id: id, title: title, status: status,
        waiting: waiting.map { TaskItem.Waiting(reason: $0.0, since: daysAgo($0.1)) },
        priority: priority, due: due.flatMap(TaskItem.DueDate.init), workspace: workspace,
        memo: memo, createdAt: daysAgo(2), createdBy: by, links: links)
    }
    let tasks = [
      task(
        1, "タスク機能の設計", .inProgress, workspace: ws[0],
        links: [taskLink(.issue, "orbe", 212), taskLink(.pr, "orbe", 213)]),
      task(
        2, "レビュー指摘に返信する", .inProgress, workspace: ws[0], links: [taskLink(.pr, "orbe", 209)]),
      task(
        3, "設定の検索を速くする", .inProgress, waiting: ("レビュー待ち", 2), workspace: ws[0],
        links: [taskLink(.pr, "orbe", 214)]),
      task(4, "見積もりの数字を経理に確認する", .inProgress, waiting: ("経理の返事", 1)),
      task(
        5, "ログイン直後に白画面になる", priority: .high, workspace: ws[1],
        links: [taskLink(.issue, "web-app", 47)]),
      task(6, "Slack で上司に来週の休みを連絡する"),
      task(7, "経費精算を出す", due: "2025-10-06"),
      task(8, "キャッシュ層を差し替える", workspace: ws[2], links: [taskLink(.pr, "api", 88)]),
      task(
        9, "Dispatch: fetch 待ちの間 Esc が効かない", workspace: ws[0],
        links: [taskLink(.issue, "orbe", 218)]),
      task(10, "control/api.md にタスクのツール節を足す", workspace: ws[0], by: "claude"),
      task(11, "歯医者の予約を取り直す", priority: .low),
      task(12, "ヘルプに ⌘⇧X を載せる", .done, workspace: ws[0]),
      task(13, "請求書を送る", .done),
      task(14, "ブランチ名の検証を直す", .done, workspace: ws[0]),
    ]
    return TasksFile(version: TaskPersistence.version, nextId: 15, tasks: tasks)
  }

  static func taskLink(_ kind: GitHubItemKind, _ repo: String, _ number: Int) -> TaskLink {
    TaskLink(item: GitHubItemID(repo: "nakatake/\(repo)", number: number)!, kind: kind)
  }

  /// 見本の GitHub の値を詰めた置き場（取得は何もしない）。自分は nakatake で、#88 だけが他人の PR。
  static func taskGitHubItems() -> GitHubItemCache {
    func pr(
      _ title: String, review: GitHubItemSummary.ReviewDecision? = .reviewRequired,
      author: String = "nakatake"
    ) -> GitHubItemAnswer {
      .found(
        GitHubItemSummary(
          title: title, state: .open,
          pullRequest: .init(isDraft: false, review: review, checks: .success, author: author)))
    }
    func issue(_ title: String) -> GitHubItemAnswer {
      .found(GitHubItemSummary(title: title, state: .open, pullRequest: nil))
    }
    let answers: [(TaskLink, GitHubItemAnswer)] = [
      (taskLink(.issue, "orbe", 212), issue("タスク機能の設計")),
      (taskLink(.pr, "orbe", 213), pr("タスク一覧の土台")),
      (taskLink(.pr, "orbe", 209), pr("worktree の掃除を速くする", review: .changesRequested)),
      (taskLink(.pr, "orbe", 214), pr("設定の検索を速くする")),
      (taskLink(.issue, "web-app", 47), issue("ログイン直後に白画面になる")),
      (taskLink(.pr, "api", 88), pr("キャッシュ層を差し替える", author: "sato")),
      (taskLink(.issue, "orbe", 218), issue("Dispatch: fetch 待ちの間 Esc が効かない")),
    ]
    return GitHubItemCache(
      answers: Dictionary(uniqueKeysWithValues: answers.map { ($0.0.item, $0.1) }),
      viewerLogin: "nakatake", fetch: { _, _ in })
  }

  static func taskPaletteModel(_ file: TasksFile? = nil) -> TaskPaletteModel {
    TaskPaletteModel(
      store: TaskStore(file: file ?? taskDesignFile()), githubItems: taskGitHubItems(),
      agents: WorktreeAgentActivity(),
      workspaces: taskWorkspaces, now: taskToday, timeZone: taskCalendar.timeZone)
  }
}
