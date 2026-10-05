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
      links: [TaskLink] = [], worktree: String? = nil
    ) -> TaskItem {
      TaskItem(
        id: id, title: title, status: status,
        waiting: waiting.map { TaskItem.Waiting(reason: $0.0, since: daysAgo($0.1)) },
        priority: priority, due: due.flatMap(TaskItem.DueDate.init), workspace: workspace,
        memo: memo, createdAt: daysAgo(2), createdBy: by, links: links,
        worktree: worktree.map(taskWorktree))
    }
    let tasks = [
      task(
        1, "タスク機能の設計", .inProgress, workspace: ws[0],
        links: [taskLink(.issue, "orbe", 212), taskLink(.pr, "orbe", 213)], worktree: "issue-212"),
      task(
        2, "レビュー指摘に返信する", .inProgress, workspace: ws[0], links: [taskLink(.pr, "orbe", 209)],
        worktree: "pr-209"),
      task(
        3, "設定の検索を速くする", .inProgress, waiting: ("レビュー待ち", 2), workspace: ws[0],
        links: [taskLink(.pr, "orbe", 214)], worktree: "pr-214"),
      task(4, "見積もりの数字を経理に確認する", .inProgress, waiting: ("経理の返事", 1)),
      task(
        5, "ログイン直後に白画面になる", priority: .high, workspace: ws[1],
        links: [taskLink(.issue, "web-app", 47)]),
      task(6, "Slack で上司に来週の休みを連絡する"),
      task(7, "経費精算を出す", due: "2025-10-06"),
      task(8, "キャッシュ層を差し替える", workspace: ws[2], links: [taskLink(.pr, "orbe", 88)]),
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

  /// 見本の worktree（`~/wt/<name>`。ファイルシステムには無い）。
  static func taskWorktree(_ name: String) -> TaskWorktree {
    TaskWorktree(key: "\(NSHomeDirectory())/wt/\(name)")
  }

  /// 見本の agent（#212 の worktree で claude が 12 分作業中、#209 の worktree で入力待ち）。
  static func taskAgents() -> WorktreeAgentActivity {
    let agent = { (name: String, state: AgentStateIcon.Kind, minutes: Double) in
      WorktreeAgentActivity.Agent(
        name: "claude", state: state, since: Date().addingTimeInterval(-minutes * 60),
        tabId: 1, tabTitle: name, branch: nil)
    }
    return WorktreeAgentActivity(agents: [
      taskWorktree("issue-212").path: agent("issue-212", .working, 12),
      taskWorktree("pr-209").path: agent("pr-209", .waiting, 3),
    ])
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
      (taskLink(.pr, "orbe", 88), pr("キャッシュ層を差し替える", author: "sato")),
      (taskLink(.issue, "orbe", 218), issue("Dispatch: fetch 待ちの間 Esc が効かない")),
    ]
    return GitHubItemCache(
      answers: Dictionary(uniqueKeysWithValues: answers.map { ($0.0.item, $0.1) }),
      viewer: GitHubViewer(login: "nakatake"), fetch: { _, _ in })
  }

  /// 見本の root（`nakatake/orbe` に解決済み）。
  static let taskRoot = "/work/orbe"
  static let taskRepo = GitHubRepoName(nameWithOwner: "nakatake/orbe")

  /// 見本 XTGitHub1.png・XTGitHub2.png の open 一覧を詰めた置き場（取得は何もしない）。Issue 24 件（自分の
  /// 担当は #212・#218）・PR 7 件（自分の作成は #213・#214・#229、自分へのレビュー依頼は個人宛の #88 と
  /// チーム宛の #231・#233）。
  static func taskOpenLists(viewer: GitHubViewer) -> GitHubOpenLists {
    let hour = { (hours: Double) in taskToday.addingTimeInterval(-hours * 3600) }
    func issue(_ number: Int, _ title: String, _ hours: Double, assignees: [String] = [])
      -> GitHubOpenItem
    {
      GitHubOpenItem(
        number: number, title: title, updatedAt: hour(hours), author: "tanaka",
        assignees: assignees, pullRequest: nil)
    }
    func pr(
      _ number: Int, _ title: String, _ hours: Double, author: String = "nakatake",
      reviewers: [String] = [], teams: [String] = []
    ) -> GitHubOpenItem {
      GitHubOpenItem(
        number: number, title: title, updatedAt: hour(hours), author: author, assignees: [],
        pullRequest: .init(
          isDraft: false, review: .reviewRequired, checks: .success, reviewers: reviewers,
          teams: teams))
    }
    let fillers = [
      "ヘルプの検索が遅い", "サイドバーの並びを覚える", "テーマの切り替えでちらつく", "通知の音量を変えたい",
      "workspace の改名で色が戻る", "タブの複製でスクロールが消える", "設定の書き出しに対応する",
      "ログの保存先を選べるようにする", "IME の候補窓がずれる", "フォントの太さが反映されない",
      "起動時に前回の窓の大きさへ戻す", "agent の終了を通知する", "コピー時に末尾の空白を落とす",
      "検索の結果に件数を出す", "分割の比率を覚える", "リンクのクリックで開くアプリを選ぶ",
      "選択範囲を共有できるようにする", "最近閉じたタブを戻す", "メニューバーの表示を切り替える",
      "ダークモードの境界線が見えにくい",
    ]
    let issues =
      [
        issue(212, "タスク機能の設計", 30, assignees: ["nakatake"]),
        issue(218, "Dispatch: fetch 待ちの間 Esc が効かない", 50, assignees: ["nakatake"]),
        issue(221, "fetch 中に進捗が出ない", 2),
        issue(220, "Settings: フォント幅の候補が狭い", 20, assignees: ["tanaka"]),
      ]
      + fillers.enumerated().map {
        issue(200 - $0.offset, $0.element, 24 + Double($0.offset) * 12, assignees: ["sato"])
      }
    let pullRequests = [
      pr(213, "タスク一覧の土台", 3),
      pr(214, "設定の検索を速くする", 26),
      pr(88, "キャッシュ層を差し替える", 40, author: "sato", reviewers: ["nakatake"]),
      pr(231, "ログ出力を整理する", 5, author: "tanaka", teams: ["orbe/core"]),
      pr(233, "クラッシュレポートの送信先を変える", 8, author: "tanaka", teams: ["orbe/core"]),
      pr(230, "docs: README を英訳する", 30, author: "sato"),
      pr(229, "ベースの既定を覚える", 70),
    ]
    var repository = GitHubOpenLists.Repository()
    repository.issues.items = issues
    repository.pullRequests.items = pullRequests
    repository.reviewRequests = [88, 231, 233]
    return GitHubOpenLists(
      roots: [taskRoot: .init(resolution: .resolved, repo: taskRepo)],
      repositories: [taskRepo: repository], source: .idle, viewer: viewer)
  }

  static func taskPaletteModel(
    _ file: TasksFile? = nil, openLists: ((GitHubViewer) -> GitHubOpenLists)? = nil
  ) -> TaskPaletteModel {
    let items = taskGitHubItems()
    return TaskPaletteModel(
      store: TaskStore(file: file ?? taskDesignFile()), githubItems: items, viewer: items.viewer,
      openLists: (openLists ?? taskOpenLists)(items.viewer), root: taskRoot,
      agents: taskAgents(),
      workspaces: taskWorkspaces, now: taskToday, timeZone: taskCalendar.timeZone)
  }
}
