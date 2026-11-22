import OrbeTestSupport
import XCTest

@testable import Orbe

/// ブランチの PR を引く段（`GitHubBranchPullRequestLookup`）。ブランチごとに GitHub 上の同一性と、
/// PR の一覧（head がその同一性と等しいものだけ）または引けない理由を答え、リポジトリの台帳も返す。
///
/// 壊れると何が起きるか: 他人の fork の同名ブランチに立った PR がタスクに付く。引けない理由を取り違える
/// （GitHub でないリポジトリを「確かめられない」と答える・gh の失敗を「PR が無い」と答える）。
extension WorktreePaletteRemoteLedgerProviderTests {
  private func lookup(_ branches: Set<String>, cache: GitHubCache = GitHubCache()) throws
    -> GitHubBranchPullRequests
  {
    let repo = try openRepo()
    var found: GitHubBranchPullRequests?
    GitHubBranchPullRequestLookup(gitHub: GitHubCLI(), cache: cache).lookup(
      repo, branches: branches
    ) { found = $0 }
    XCTAssertTrue(waitUntil(20) { found != nil })
    return try XCTUnwrap(found)
  }

  private func openRepo() throws -> GitRepo {
    var repo: GitRepo?
    GitRepo.open(cwd: root) { repo = $0 }
    XCTAssertTrue(waitUntil(20) { repo != nil })
    return try XCTUnwrap(repo)
  }

  /// 同一性が GitHub のブランチと決まれば、head がリポジトリまで含めてその同一性と等しい PR だけを返す。
  func testTheBranchAnswersItsIdentityAndOnlyItsOwnPullRequests() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    XCTAssertTrue(git(["branch", "feat"]).isSuccess)
    try serveBranchPullRequests(
      "feat",
      "["
        + [
          branchPR(9, head: "feat", state: "OPEN", from: "stranger/r"),
          branchPR(8, head: "feat", state: "CLOSED", from: "me/r"),
          branchPR(7, head: "feat", state: "OPEN", from: "me/r"),
        ].joined(separator: ",") + "]")

    let found = try lookup(["feat"])

    let ref = GitHubBranchRef(repo: mine, branch: "feat")
    XCTAssertEqual(found.ledger?.repository(forPushRemote: nil), .github(mine))
    guard case .gitHub(ref, .success(let pullRequests))? = found.branches["feat"] else {
      return XCTFail("GitHub のブランチと決まり、PR の一覧が返る: \(String(describing: found.branches["feat"]))")
    }
    XCTAssertEqual(pullRequests.map(\.number), [8, 7])
  }

  /// GitHub でないリポジトリは gh に問い合わせず、台帳も同一性も持たない。
  func testANonGitHubRepositoryIsNotGitHub() throws {
    XCTAssertTrue(git(["remote", "add", "origin", "https://gitlab.com/me/r.git"]).isSuccess)
    XCTAssertTrue(git(["branch", "feat"]).isSuccess)

    let found = try lookup(["feat"])

    XCTAssertNil(found.ledger)
    XCTAssertEqual(
      found.branches["feat"], GitHubBranchPullRequests.Branch.unavailable(.notGitHub))
    XCTAssertTrue(calls("H").isEmpty, "PR は問い合わせない")
  }

  /// push 先の remote の正式名を確かめられないブランチは「確かめられない」で、PR を問い合わせない（「GitHub でない」と
  /// 読まない）。
  func testABranchPushedToAnUnverifiedRemoteIsUnverified() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    addRemote("gone", "me/gone")
    try answerNotFound("me/gone")
    XCTAssertTrue(git(["branch", "feat"]).isSuccess)
    XCTAssertTrue(git(["config", "branch.feat.pushRemote", "gone"]).isSuccess)

    let found = try lookup(["feat"])

    XCTAssertEqual(
      found.branches["feat"], GitHubBranchPullRequests.Branch.unavailable(.unverified))
    XCTAssertTrue(calls("H").isEmpty, "PR は問い合わせない")
  }

  /// 問い合わせの失敗は、失敗の種類つきで、そのブランチだけに限られる。
  func testAFailedQueryCarriesTheFailureForThatBranchOnly() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    XCTAssertTrue(git(["branch", "feat"]).isSuccess)
    XCTAssertTrue(git(["branch", "other"]).isSuccess)
    try serveBranchPullRequests("feat", "")
    let branchFile = ghDir.appendingPathComponent("branch/feat").path
    try write("error connecting to api.github.com\n", to: branchFile + ".stderr")
    try write("1", to: branchFile + ".exit")

    let found = try lookup(["feat", "other"])

    XCTAssertEqual(
      found.branches["feat"],
      .gitHub(GitHubBranchRef(repo: mine, branch: "feat"), pullRequests: .failure(.unreachable)))
    XCTAssertEqual(
      found.branches["other"],
      .gitHub(GitHubBranchRef(repo: mine, branch: "other"), pullRequests: .success([])))
  }

  /// PR は、同一性のリポジトリを名指しして引く。fork でなければ問い合わせは 1 回。
  func testABranchOfANonForkAsksOnlyItsOwnRepository() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    XCTAssertTrue(git(["branch", "feat"]).isSuccess)

    _ = try lookup(["feat"])

    XCTAssertEqual(calls("P"), ["me/r feat"])
  }

  /// push 先が fork なら、fork と親の両方を名指しして引き、作成日時の新しい順にまとめる——fork から親へ出した PR も、
  /// fork の中の PR も、そのブランチの PR になる。
  func testAForkBranchAlsoAsksTheParentAndMergesByCreation() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r", parent: "up/r")
    XCTAssertTrue(git(["branch", "feat"]).isSuccess)
    try serveBranchPullRequests(
      "feat", in: "me/r",
      "["
        + [
          branchPR(
            5, head: "feat", state: "CLOSED", from: "me/r", createdAt: "2026-03-01T00:00:00Z"),
          branchPR(
            3, head: "feat", state: "CLOSED", from: "me/r", createdAt: "2026-01-01T00:00:00Z"),
        ].joined(separator: ",") + "]")
    try serveBranchPullRequests(
      "feat", in: "up/r",
      "["
        + [
          branchPR(9, head: "feat", state: "OPEN", from: "me/r", createdAt: "2026-02-01T00:00:00Z"),
          branchPR(
            8, head: "feat", state: "OPEN", from: "stranger/r", createdAt: "2026-01-15T00:00:00Z"),
        ].joined(separator: ",") + "]")

    let found = try lookup(["feat"])

    XCTAssertEqual(Set(calls("P")), ["me/r feat", "up/r feat"])
    XCTAssertEqual(found.branches["feat"]?.pullRequests?.map(\.number), [5, 9, 3])
  }

  /// ブランチの PR を引く段は、⌘T の clean が持つブランチの PR のキャッシュを書き換えない——clean は gh の既定の
  /// リポジトリから取った値で先に判定するので、問い合わせ先の違う（push 先と親の）値が混ざると、判定が描いた後に変わる。
  func testTheLookupLeavesTheCleansCachedPullRequestsAlone() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r", parent: "up/r")
    XCTAssertTrue(git(["branch", "feat"]).isSuccess)
    try serveBranchPullRequests(
      "feat", in: "up/r", "[" + branchPR(9, head: "feat", state: "MERGED", from: "me/r") + "]")
    let cache = GitHubCache()
    let commonDir = try openRepo().commonDir
    let cleans = [
      GitHubBranchPR(
        number: 4, headRefName: "feat", state: "OPEN", baseRefName: "main", headRepository: mine,
        url: "https://github.com/me/r/pull/4")
    ]
    cache.setBranchPullRequests(cleans, head: "feat", for: commonDir)

    _ = try lookup(["feat"], cache: cache)

    XCTAssertEqual(cache.entry(for: commonDir)?.branchPullRequests, ["feat": cleans])
  }

  /// fork と親のどちらかの問い合わせが失敗すれば、そのブランチの答えは失敗——引けた側の PR だけで「無い」とも
  /// 「これだけ」とも読ませない。
  func testAFailedQueryOnEitherSideFailsTheForkBranch() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r", parent: "up/r")
    XCTAssertTrue(git(["branch", "feat"]).isSuccess)
    for (failing, answering) in [("me/r", "up/r"), ("up/r", "me/r")] {
      let failingFile = ghDir.appendingPathComponent(
        "branch/\(failing.replacingOccurrences(of: "/", with: "__"))__feat"
      ).path
      let answeringFile = ghDir.appendingPathComponent(
        "branch/\(answering.replacingOccurrences(of: "/", with: "__"))__feat"
      ).path
      for leftover in [answeringFile + ".stderr", answeringFile + ".exit"] {
        try? FileManager.default.removeItem(atPath: leftover)
      }
      try serveBranchPullRequests(
        "feat", in: answering, "[" + branchPR(3, head: "feat", state: "OPEN", from: "me/r") + "]")
      try write("", to: failingFile)
      try write("error connecting to api.github.com\n", to: failingFile + ".stderr")
      try write("1", to: failingFile + ".exit")

      let found = try lookup(["feat"])

      XCTAssertEqual(
        found.branches["feat"],
        .gitHub(GitHubBranchRef(repo: mine, branch: "feat"), pullRequests: .failure(.unreachable)),
        "\(failing) の問い合わせが失敗")
    }
  }

  /// 作成ページの URL は push の後に GitHub が案内するもの。ブランチ名の `/` は残し、URL で意味を持つ文字はエンコードする。
  func testThePullRequestCreationURL() {
    XCTAssertEqual(
      GitHubBranchRef(repo: mine, branch: "feat/a#1").pullRequestCreationURL?.absoluteString,
      "https://github.com/me/r/pull/new/feat/a%231")
  }
}
