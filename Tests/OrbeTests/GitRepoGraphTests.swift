import OrbeTestSupport
import XCTest

@testable import Orbe

/// コミットグラフ（実 git）: 既定の範囲（HEAD と upstream）で、各コミットの親・題・指している local / remote のブランチ名・
/// push 済みかが読め、件数を区切って続きを読め、範囲の ref を選べ、ユーザーの設定で出力が変わらない。
///
/// 壊れると何が起きるか。upstream にだけあるコミットが出ない・merge の線が繋がらない・push 済みの印が嘘をつく・
/// `log.showSignature` の利用者で題が署名の行に化ける。
final class GitRepoGraphTests: OrbeTestCase {
  private var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  private func graph(
    _ git: GitRepo, refs: [String]? = nil, skip: Int = 0, limit: Int = 50
  ) -> GitCommitGraph? {
    var result: GitCommitGraph?
    let done = expectation(description: "graph")
    git.commitGraph(refs: refs, skip: skip, limit: limit) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return result
  }

  private func commit(_ subject: String) {
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", subject]).isSuccess)
  }

  /// HEAD と upstream の両方から届くコミットが出て、push 済みかと指しているブランチが読める。
  func testTheDefaultRangeCoversHeadAndUpstream() throws {
    let git = try repo.open()
    let initial = repo.head()
    repo.addOrigin()
    try repo.advanceOrigin(writing: "o.txt", "o\n")
    XCTAssertTrue(repo.git(["fetch", "-q"]).isSuccess)
    commit("local")
    XCTAssertTrue(repo.git(["branch", "a,b"]).isSuccess)
    let local = repo.head()
    let remote = repo.git(["rev-parse", "origin/main"]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let commits = try XCTUnwrap(graph(git)).commits
    XCTAssertEqual(Set(commits.map(\.oid)), [local, remote, initial])
    let byOid = Dictionary(uniqueKeysWithValues: commits.map { ($0.oid, $0) })
    XCTAssertEqual(byOid[local]?.parents, [initial])
    XCTAssertEqual(byOid[local]?.subject, "local")
    XCTAssertEqual(byOid[local]?.localBranches.sorted(), ["a,b", "main"])
    XCTAssertEqual(byOid[local]?.isPushed, false)
    XCTAssertEqual(byOid[remote]?.remoteBranches, ["origin/main"], "origin/HEAD は含まない")
    XCTAssertEqual(byOid[remote]?.isPushed, true)
    XCTAssertEqual(byOid[initial]?.isPushed, true)
    XCTAssertEqual(byOid[initial]?.parents, [])
  }

  /// 件数を区切って続きを読め、呼び出し側が範囲の ref を選べる。remote 追跡ブランチが無ければ全部「未 push」。
  func testPagesAndChosenRefs() throws {
    let git = try repo.open()
    for index in 1...4 { commit("c\(index)") }
    XCTAssertTrue(repo.git(["branch", "side", "HEAD~2"]).isSuccess)

    let first = try XCTUnwrap(graph(git, limit: 2))
    XCTAssertEqual(first.commits.map(\.subject), ["c4", "c3"])
    XCTAssertTrue(first.hasMore)
    let rest = try XCTUnwrap(graph(git, skip: 2, limit: 10))
    XCTAssertEqual(rest.commits.map(\.subject), ["c2", "c1", "init"])
    XCTAssertFalse(rest.hasMore)
    XCTAssertTrue(rest.commits.allSatisfy { !$0.isPushed })

    XCTAssertEqual(
      try XCTUnwrap(graph(git, refs: ["side"])).commits.map(\.subject), ["c2", "c1", "init"])
  }

  /// ユーザーの `log.showSignature`・色・出力の文字コードの設定で、出力が変わらない。
  func testUserLogSettingsDoNotChangeTheOutput() throws {
    let git = try repo.open()
    let key = TestScratch.caseDir.appendingPathComponent("signing-key").path
    let keygen = Process()
    keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", key]
    try keygen.run()
    keygen.waitUntilExit()
    for args in [
      ["config", "gpg.format", "ssh"], ["config", "user.signingkey", key],
      ["config", "commit.gpgsign", "true"], ["config", "log.showSignature", "true"],
      ["config", "color.ui", "always"], ["config", "i18n.logOutputEncoding", "ISO-8859-1"],
      ["config", "log.decorate", "full"],
    ] {
      XCTAssertTrue(repo.git(args).isSuccess)
    }
    commit("signed é")

    let commits = try XCTUnwrap(graph(git)).commits
    XCTAssertEqual(commits.map(\.subject), ["signed é", "init"])
    XCTAssertEqual(commits.first?.oid, repo.head())
  }
}
