import OrbeTestSupport
import XCTest

@testable import Orbe

/// `start_task` のリポジトリの作業場の決定（`TaskRepoWorktree`）が、主が PR のタスクで head の取得の答えを待つ間も、
/// 取得が失敗したら決め直して必ず 1 度答えること。
///
/// 壊れると何が起きるか: gh が遅れて失敗すると start_task が永久に応答せず、秘書の claude がその後の Orbe のツールまで
/// 待たされる。
final class TaskRepoWorktreeTests: OrbeTestCase {
  func testAFailedFetchOfThePullRequestHeadStillGetsAnAnswer() throws {
    // origin は手元の bare（fetch がすぐ着地し、GitHub でないので gh も問わない）。主の PR のリポジトリは upstream。
    let dir = TestScratch.caseDir.path
    let origin = (dir as NSString).appendingPathComponent("origin.git")
    let repo = (dir as NSString).appendingPathComponent("repo")
    for (args, cwd) in [
      (["init", "-q", "--bare", "-b", "main", origin], dir), (["clone", "-q", origin, repo], dir),
      (["config", "user.email", "t@example.com"], repo), (["config", "user.name", "t"], repo),
      (["commit", "-q", "--allow-empty", "-m", "a"], repo),
      (["push", "-q", "origin", "HEAD:main"], repo),
      (["remote", "add", "upstream", "https://github.com/o/n.git"], repo),
    ] {
      XCTAssertTrue(GitRunner.shared.runSync(args, cwd: cwd).isSuccess, args.joined(separator: " "))
    }
    var batch: (([GitHubItemID], GitHubItemsBatch?) -> Void)?
    var asked: [GitHubItemID] = []
    let items = GitHubItemCache(fetch: { ids, done in
      asked = ids
      batch = done
    })
    var draft = TaskDraft(title: "PR を直す")
    draft.links = [TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "o/n", number: 7)), kind: .pr)]
    let task = try TaskStore(file: nil).add(draft)
    var facts: WorktreeRepoFacts?
    let start = TaskRepoWorktree(
      task: task, branch: nil, candidates: [repo], items: items,
      makeFacts: {
        let made = WorktreeRepoFacts(
          cwd: $0, localization: LocalizationStore(language: .en), worktreeTemplate: "")
        facts = made
        return made
      })
    var outcome: Result<TaskWorkplace, TaskStartFailure>?

    start.start { outcome = $0 }
    XCTAssertTrue(
      waitUntil(20) {
        facts?.remoteFetchLanded == true && facts?.probedGitHubState != nil
          && facts?.hasRemote(for: task.links[0].item.repo) == true
      }, "前提: リポジトリの事実が出揃い、head の答えだけを待つ")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    XCTAssertNil(outcome, "前提: head の答えを待っている")
    batch?(asked, nil)

    XCTAssertTrue(waitUntil(20) { outcome != nil }, "取得が失敗しても答える")
    guard case .failure(.invalid(let message))? = outcome else {
      return XCTFail("決まらないので拒む: \(String(describing: outcome))")
    }
    XCTAssertTrue(message.contains("pass branch"), message)
  }
}
