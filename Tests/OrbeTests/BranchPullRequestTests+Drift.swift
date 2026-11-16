import XCTest

@testable import Orbe

/// worktree の今の PR の、手元とのずれ——手元の HEAD と PR の先頭の間で数え、diff の両端には依らない。
///
/// 壊れると何が起きるか: PR のベースブランチが動いたり両端が取れなくなったりすると、ずれの帯が消えるか「違う」に化ける。
/// 見直した後に PR の中身が変わっても、ずれが数え直されない。浅いクローンで、浅い境界までの誤った数が出る。
extension BranchPullRequestTests {
  /// PR のベースブランチだけが進んで両端が変わっても、両端を求め直している間も揃った後も、手元とのずれは一致のまま。
  func testTheDriftStaysCountedWhenOnlyTheBaseMoves() throws {
    let pullRequest = try watchAnOpenPullRequest()
    pumpMain(until: { pullRequest.drift == .inSync }, "一致")
    let state = try XCTUnwrap(pullRequest.state)
    let advanced = repo.git(["commit-tree", "main^{tree}", "-p", "main", "-m", "base"]).stdoutText
      .trimmingCharacters(in: .newlines)
    XCTAssertTrue(repo.git(["update-ref", "refs/heads/main", advanced]).isSuccess)
    content = pullRequestContent(base: advanced)
    state.reload()
    guard case .fetching = state.bounds else { return XCTFail("前提: 求め直している \(state.bounds)") }
    XCTAssertEqual(pullRequest.drift, .inSync, "求め直している間も消えない")
    pumpMain(
      until: {
        if case .ready(let ends, _) = state.bounds { ends.base == advanced } else { false }
      },
      "新しいベースで両端が揃う")
    XCTAssertEqual(pullRequest.drift, .inSync)
  }

  /// 両端が取れなくなっても（PR のベース側のコミットが手元に無い）、数えたずれのまま。
  func testTheDriftStaysCountedWhenTheBoundsCannotBeResolved() throws {
    let pullRequest = try watchAnOpenPullRequest(head: "main")
    pumpMain(until: { pullRequest.drift == .diverged(ahead: 1, behind: 0) }, "手元が 1 つ先行")
    let state = try XCTUnwrap(pullRequest.state)
    content = pullRequestContent(base: String(repeating: "0", count: 40), head: "main")
    state.reload()
    pumpMain(
      until: { if case .failed(_, .commitsMissing) = state.bounds { true } else { false } },
      "両端が取れない")
    XCTAssertEqual(pullRequest.drift, .diverged(ahead: 1, behind: 0))
  }

  /// 見ている者が去って戻った後も、PR の中身が変われば手元とのずれを数え直す。
  func testTheDriftFollowsThePullRequestAfterWatchingAgain() throws {
    let pullRequest = try watchAnOpenPullRequest()
    let root = RootFiles.shared(for: repo.root)
    pumpMain(until: { pullRequest.drift == .inSync }, "一致")
    pullRequest.endWatching()
    pullRequest.beginWatching()
    pumpMain(until: { self.lookups.count == 2 }, "前提: 見直して問い直した")
    let state = try XCTUnwrap(pullRequest.state)

    content = pullRequestContent(base: try commit("main"), head: "main")
    state.reload()
    pumpMain(until: { pullRequest.drift == .diverged(ahead: 1, behind: 0) }, "数え直す")
    XCTAssertTrue(root.isResolved, "前提: 根のサービスは持ったまま")
  }

  /// 浅いクローンで、手元の HEAD と PR の先頭が浅い境界より古い所で分かれていれば、ずれを数にせず、違うとだけ持つ。
  func testADriftBeyondAShallowBoundaryIsOnlyADifference() throws {
    let bare = repo.addOrigin()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "pr"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "pr"]).isSuccess)
    let head = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "main"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "main"]).isSuccess)
    let base = repo.head()
    XCTAssertTrue(repo.git(["push", "-q", "origin", "main", "pr"]).isSuccess)
    let shallow = try TempGitRepo(name: "orbe-shallow", initialCommit: false)
    XCTAssertTrue(shallow.git(["remote", "add", "origin", "file://" + bare]).isSuccess)
    XCTAssertTrue(shallow.git(["fetch", "-q", "--depth", "1", "origin", "main", "pr"]).isSuccess)
    XCTAssertTrue(shallow.git(["switch", "-q", "-c", "feat", "FETCH_HEAD"]).isSuccess)
    XCTAssertTrue(shallow.git(["reset", "-q", "--hard", base]).isSuccess)
    repo = shallow
    content = pullRequestContent(base: base, head: head)
    answers["feat"] = .gitHub(
      GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([pr(9, state: "OPEN")]))

    let pullRequest = watch()

    pumpMain(until: { pullRequest.state?.content != nil }, "前提: PR の中身が届く")
    pumpMain(until: { pullRequest.drift == .differs }, "数にしない")
  }

  /// `revision` のコミット。
  private func commit(_ revision: String) throws -> String {
    let output = repo.git(["rev-parse", revision])
    XCTAssertTrue(output.isSuccess)
    return output.stdoutText.trimmingCharacters(in: .newlines)
  }
}
