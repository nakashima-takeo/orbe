import XCTest

@testable import Orbe

/// ブランチの PR を引く段（`GitHubBranchPullRequestLookup`）。ブランチごとに GitHub 上の同一性と、
/// PR の一覧（head がその同一性と等しいものだけ）または引けない理由を答え、リポジトリの台帳も返す。
///
/// 壊れると何が起きるか: 他人の fork の同名ブランチに立った PR がタスクに付く。引けない理由を取り違える
/// （GitHub でないリポジトリを「確かめられない」と答える・gh の失敗を「PR が無い」と答える）。
extension WorktreePaletteRemoteLedgerProviderTests {
  private func lookup(_ branches: Set<String>) throws -> GitHubBranchPullRequests {
    var repo: GitRepo?
    GitRepo.open(cwd: root) { repo = $0 }
    XCTAssertTrue(pump { repo != nil })
    var found: GitHubBranchPullRequests?
    GitHubBranchPullRequestLookup(gitHub: GitHubCLI(), cache: GitHubCache()).lookup(
      try XCTUnwrap(repo), branches: branches
    ) { found = $0 }
    XCTAssertTrue(pump { found != nil })
    return try XCTUnwrap(found)
  }

  /// 同一性が GitHub のブランチと決まれば、head がリポジトリまで含めてその同一性と等しい PR だけを、
  /// gh の並び（作成日時の新しい順）のまま返す。
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
    XCTAssertEqual(found.availability, .ready)
    XCTAssertEqual(found.ledger?.repository(forPushRemote: nil), .github(mine))
    XCTAssertEqual(found.branches["feat"]?.identity, .ref(ref))
    XCTAssertEqual(try found.branches["feat"]?.pullRequests.get().map(\.number), [8, 7])
  }

  /// GitHub でないリポジトリは gh に問い合わせず、台帳も同一性も持たない。
  func testANonGitHubRepositoryIsNotGitHub() throws {
    XCTAssertTrue(git(["remote", "add", "origin", "https://gitlab.com/me/r.git"]).isSuccess)
    XCTAssertTrue(git(["branch", "feat"]).isSuccess)

    let found = try lookup(["feat"])

    XCTAssertEqual(found.availability, .notGitHub)
    XCTAssertNil(found.ledger)
    XCTAssertEqual(
      found.branches["feat"],
      GitHubBranchPullRequests.Branch(identity: nil, pullRequests: .failure(.notGitHub)))
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
      found.branches["feat"],
      GitHubBranchPullRequests.Branch(identity: .unverified, pullRequests: .failure(.unverified)))
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

    XCTAssertEqual(found.branches["feat"]?.pullRequests, .failure(.failed(.unreachable)))
    XCTAssertEqual(
      found.branches["feat"]?.identity, .ref(GitHubBranchRef(repo: mine, branch: "feat")))
    XCTAssertEqual(found.branches["other"]?.pullRequests, .success([]))
  }

  /// 作成ページの URL は push の後に GitHub が案内するもの。ブランチ名の `/` は残し、URL で意味を持つ文字はエンコードする。
  func testThePullRequestCreationURL() {
    XCTAssertEqual(
      GitHubBranchRef(repo: mine, branch: "feat/a#1").pullRequestCreationURL?.absoluteString,
      "https://github.com/me/r/pull/new/feat/a%231")
  }
}
