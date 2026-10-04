import Foundation

@testable import Orbe

/// タスクから開いた ⌘T の fixture（見本 XTIssue / XTIssueMain / XTPR）。
extension DesignSceneFixtures {
  /// ⌘T の見本のタスク。#212（~/wt/issue-212 で claude が作業中）・#214（~/wt/pr-214・待ち）と、⌘T を開く
  /// 元の #221（Issue）・#230（PR）。
  static func worktreePaletteTasks() -> TaskStore {
    let now = taskToday
    func task(
      _ id: Int, _ title: String, _ status: TaskItem.Status, _ link: TaskLink,
      waiting: String? = nil, worktree: String? = nil
    ) -> TaskItem {
      TaskItem(
        id: id, title: title, status: status,
        waiting: waiting.map { TaskItem.Waiting(reason: $0, since: now) }, priority: .medium,
        due: nil, workspace: nil, memo: "", createdAt: now, createdBy: nil, links: [link],
        worktree: worktree.map(taskWorktree))
    }
    let tasks = [
      task(1, "タスク機能の設計", .inProgress, taskLink(.issue, "orbe", 212), worktree: "issue-212"),
      task(
        2, "設定の検索を速くする", .inProgress, taskLink(.pr, "orbe", 214), waiting: "レビュー待ち",
        worktree: "pr-214"),
      task(3, "fetch 中に進捗が出ない", .todo, taskLink(.issue, "orbe", 221)),
      task(4, "docs: README を英訳する", .todo, taskLink(.pr, "orbe", 230)),
    ]
    return TaskStore(file: TasksFile(version: TaskPersistence.version, nextId: 5, tasks: tasks))
  }

  /// Issue #221 のタスクから開いたところ（XTIssue）。先頭の欄に「＋ issue/221 を作る」が選ばれ、ベースは
  /// 前回。`base` を渡すとそのベースを選ぶ（XTIssueMain は既定）。
  static func worktreePaletteIssueModel(base: WorktreeBaseRole? = nil) -> WorktreePaletteModel {
    var input = WorktreePaletteSectionBuilder.Input.designSample
    input.taskTarget = .branch(name: "issue/221", pullRequest: nil, remotes: ["origin"])
    input.taskNumber = 221
    input.newBranchRules = designNewBranchRules
    let model = worktreePaletteModel(from: input, task: 3)
    setDesignBase(model)
    model.selectedBaseRole = base
    return model
  }

  /// PR #230 のタスクから開いたところ（XTPR）。先頭の欄に PR のブランチ（ローカルにある）が選ばれる。
  static func worktreePalettePullRequestModel() -> WorktreePaletteModel {
    var input = WorktreePaletteSectionBuilder.Input.designSample
    input.localBranches.append(
      GitBranch(name: "docs/readme-en", relativeDate: "5h ago", upstream: nil))
    input.taskTarget = .branch(name: "docs/readme-en", pullRequest: 230, remotes: ["origin"])
    input.taskNumber = 230
    let model = worktreePaletteModel(from: input, task: 4)
    setDesignBase(model)
    return model
  }

  /// 作成行の衝突の規則（見本の worktree とブランチ）。
  static var designNewBranchRules: WorktreeNewBranchRules {
    let home = NSHomeDirectory()
    return WorktreeNewBranchRules(
      takenNames: ["issue/212", "pr-214", "perf/render-batching", "fix/login-blank"],
      worktreePaths: ["\(home)/wt/issue-212", "\(home)/wt/pr-214"],
      template: "~/wt/{slug}", repoPath: "\(home)/src/orbe")
  }

  /// 見本のベースの選択肢（前回 origin/release/0.8・既定 origin/main・現在 issue/212）。
  static func setDesignBase(_ model: WorktreePaletteModel) {
    model.newBranchRules = designNewBranchRules
    model.baseFacts = WorktreeBaseFacts(
      previous: "origin/release/0.8", defaultBranch: "origin/main", current: "issue/212")
  }
}
