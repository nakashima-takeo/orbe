import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// タスクから開いた ⌘T のカードが、主の PR の値を頼み、その答え（取れても取れなくても）で預かった ↵ を解く
/// 配線。
///
/// 壊れると何が起きるか: 開いている間に agent がタスクの主を PR に変えると、その値を誰も頼まず、↵ が
/// 預かられたままパレットが閉じられなくなる。
extension WorktreePaletteCardKeyTests {
  /// 頼まれた項目を溜め、答えはテストが渡す取得。
  private final class PendingItems {
    private(set) var requested: [GitHubItemID] = []
    private var answers: [([GitHubItemID], GitHubItemsBatch?) -> Void] = []
    lazy var cache = GitHubItemCache { ids, batch in
      self.requested += ids
      self.answers.append(batch)
    }

    func answer(_ ids: [GitHubItemID], _ batch: GitHubItemsBatch?) {
      guard !answers.isEmpty else { return XCTFail("取得が頼まれていない") }
      answers.removeFirst()(ids, batch)
    }
  }

  private var pr: TaskLink { TaskPaletteSamples.link(.pr, 230, repo: "me/r") }

  /// 1 コミットのリポジトリ（remote なし）を caseDir に作る。
  private func repository() throws -> String {
    let dir = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("repo").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for args in [
      ["init", "-q", "-b", "main"], ["config", "user.email", "t@example.com"],
      ["config", "user.name", "t"], ["commit", "-q", "--allow-empty", "-m", "init"],
    ] {
      XCTAssertTrue(GitRunner.shared.runSync(args, cwd: dir).isSuccess, "git \(args[0])")
    }
    return dir
  }

  private func taskModel(_ links: [TaskLink], items: GitHubItemCache) -> WorktreePaletteModel {
    let task = TaskPaletteSamples.task(1, "a") { $0.links = links }
    let store = TaskStore(
      file: TasksFile(version: TaskPersistence.version, nextId: 2, tasks: [task]))
    return WorktreePaletteModel(tasks: store, githubItems: items, task: 1)
  }

  private func wait(_ condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { pump(0.02) }
    return condition()
  }

  func testOpeningAskedForThePrimaryPullRequest() {
    let items = PendingItems()

    _ = mount(taskModel([pr], items: items.cache))

    XCTAssertEqual(items.requested, [pr.item])
  }

  func testAPullRequestBecomingThePrimaryWhileOpenIsAskedFor() throws {
    let items = PendingItems()
    let model = taskModel([], items: items.cache)
    _ = mount(model)
    XCTAssertEqual(items.requested, [], "前提: 主が無い間は頼まない")

    var update = TaskUpdate()
    update.links = [pr]
    _ = try model.tasks.update(1, update)
    pump(0.3)

    XCTAssertEqual(items.requested, [pr.item])
  }

  /// PR の値を待つ間に押した ↵ は預かり、値が取れても取れなくても、届いた時点で解けて行に効く。
  func testEnterHeldForThePullRequestIsReleasedWhetherItsValueArrivesOrNot() throws {
    let root = try repository()
    let head = GitHubBranchRef(repo: GitHubRepoName(nameWithOwner: "me/r"), branch: "feat")
    let found = GitHubItemsBatch(
      viewerLogin: nil,
      answers: [
        pr.item: .found(
          GitHubItemSummary(
            title: "pr", state: .open,
            pullRequest: .init(isDraft: false, review: nil, checks: nil, author: "me", head: head)))
      ])
    for (name, batch) in [("取れた", found), ("取れなかった", nil)] {
      let items = PendingItems()
      let model = taskModel([pr], items: items.cache)
      let provider = WorktreePaletteDataProvider(
        cwd: root, model: model, localization: LocalizationStore(language: .ja),
        worktreeTemplate: WorktreePathTemplate.defaultTemplate, gitHub: GitHubCLI())
      model.onTaskInputsChanged = { provider.rebuild() }
      var executed: [WorktreePaletteDestination] = []
      model.onExecute = { executed.append($0) }
      _ = mount(model)
      provider.load()
      XCTAssertTrue(wait { model.hasLoadedOnce && provider.remoteFetchLanded }, "\(name): 前提")
      model.activate()
      XCTAssertTrue(model.hasPendingActivation, "\(name): 値が届くまで ↵ を預かる")

      items.answer([pr.item], batch)

      XCTAssertTrue(wait { !executed.isEmpty }, "\(name): 預かった ↵ が解ける")
      withExtendedLifetime(provider) {}
    }
  }
}
