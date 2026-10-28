import OrbeTestSupport
import XCTest

@testable import Orbe

/// worktree パレットが自分の用で走らせる fetch（提示時の `fetch --prune`・最新化の fetch）は、remote 追跡 ref を取り込み、
/// FETCH_HEAD を書かない（実 git）。
///
/// 壊れると、端末で `git fetch <remote> <ref>` の後に FETCH_HEAD を使う手順（checkout・cherry-pick・reset）が、⌘T や
/// `start_task` を挟んだだけで別のコミットへ黙って向かう。
final class GitRepoWorktreesFetchTests: OrbeTestCase {
  func testPaletteFetchesLeaveFetchHeadAlone() throws {
    let repo = try TempGitRepo()
    repo.addOrigin()
    XCTAssertTrue(repo.git(["branch", "feat", "--track", "origin/main"]).isSuccess)
    try repo.advanceOrigin(writing: "p.txt", "p\n", onto: "pr")
    XCTAssertTrue(repo.git(["fetch", "-q", "origin", "pr"]).isSuccess)
    let fetchHead = repo.root + "/.git/FETCH_HEAD"
    let before = try String(contentsOfFile: fetchHead, encoding: .utf8)
    let git = try repo.open()

    try repo.advanceOrigin(writing: "m.txt", "m\n")
    let fetched = expectation(description: "fetchPrune")
    git.fetchPrune {
      XCTAssertTrue($0)
      fetched.fulfill()
    }
    wait(for: [fetched], timeout: 20)
    XCTAssertEqual(rev("origin/main", repo), originMain(repo), "提示時の fetch は remote 追跡 ref を取り込む")
    XCTAssertEqual(try String(contentsOfFile: fetchHead, encoding: .utf8), before, "提示時の fetch")

    try repo.advanceOrigin(writing: "n.txt", "n\n")
    let upstream = GitUpstream(
      short: "origin/main", ref: "refs/remotes/origin/main", remote: "origin",
      remoteRef: "refs/heads/main", track: nil)
    var failure: GitRefreshFailure?
    let advanced = expectation(description: "fastForwardBranch")
    git.fastForwardBranch(name: "feat", upstream: upstream) {
      failure = $0
      advanced.fulfill()
    }
    wait(for: [advanced], timeout: 20)
    XCTAssertNil(failure)
    XCTAssertEqual(rev("feat", repo), originMain(repo), "最新化はローカルのブランチを upstream へ進める")
    XCTAssertEqual(try String(contentsOfFile: fetchHead, encoding: .utf8), before, "最新化の fetch")
  }

  private func rev(_ name: String, _ repo: TempGitRepo) -> String {
    repo.git(["rev-parse", name]).stdoutText.trimmingCharacters(in: .newlines)
  }

  private func originMain(_ repo: TempGitRepo) -> String {
    String(repo.git(["ls-remote", "origin", "refs/heads/main"]).stdoutText.prefix { $0 != "\t" })
  }
}
