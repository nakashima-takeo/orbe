import OrbeTestSupport
import XCTest

@testable import Orbe

/// コミットグラフ（実 git）: HEAD と upstream から届くコミットの題・指している local / remote のブランチ名・push 済みかが
/// 読め、件数を区切って読んでその先があるかも分かり、ユーザーの設定で出力が変わらない。HEAD の push 済みはグラフを通らず
/// 同じ定義で読める。
///
/// 壊れると何が起きるか。upstream にだけあるコミットが出ない・push 済みの印が嘘をつく・さらに表示が出ない・
/// `log.showSignature` の利用者で題が署名の行に化ける・push した直後に amend・取り消しが押せる。
final class GitRepoGraphTests: OrbeTestCase {
  private var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  private func graph(_ git: GitRepo, limit: Int = 50) -> GitCommitGraph? {
    var result: GitCommitGraph?
    let done = expectation(description: "graph")
    git.commitGraph(limit: limit) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return result
  }

  private func headPush(_ git: GitRepo) -> (commit: String, isPushed: Bool)? {
    var result: (commit: String, isPushed: Bool)?
    let done = expectation(description: "headPush")
    git.headPush {
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
    XCTAssertEqual(byOid[local]?.subject, "local")
    XCTAssertEqual(byOid[local]?.localBranches.sorted(), ["a,b", "main"])
    XCTAssertEqual(byOid[local]?.isPushed, false)
    XCTAssertEqual(byOid[remote]?.remoteBranches, ["origin/main"], "origin/HEAD は含まない")
    XCTAssertEqual(byOid[remote]?.isPushed, true)
    XCTAssertEqual(byOid[initial]?.isPushed, true)
  }

  /// 件数を区切って読み、その先があるかも分かる（件数を増やして読み直せば残りが出る）。remote 追跡ブランチが無ければ全部
  /// 「未 push」。初回コミット前は（失敗でなく）空。
  func testItReadsUpToALimitAndTellsWhetherMoreFollow() throws {
    let git = try repo.open()
    for index in 1...4 { commit("c\(index)") }

    let first = try XCTUnwrap(graph(git, limit: 2))
    XCTAssertEqual(first.commits.map(\.subject), ["c4", "c3"])
    XCTAssertTrue(first.hasMore)
    let all = try XCTUnwrap(graph(git, limit: 10))
    XCTAssertEqual(all.commits.map(\.subject), ["c4", "c3", "c2", "c1", "init"])
    XCTAssertFalse(all.hasMore)
    XCTAssertTrue(all.commits.allSatisfy { !$0.isPushed })

    let fresh = try TempGitRepo(initialCommit: false)
    XCTAssertEqual(graph(try fresh.open()), GitCommitGraph(commits: [], hasMore: false))
  }

  /// HEAD の push 済みは、グラフと同じ定義（どれかの remote 追跡ブランチから届く）で HEAD 1 件だけを読む。upstream が先に
  /// 進んでいても（グラフの先頭を upstream が占めても）HEAD のコミットで答える。初回コミット前は nil。
  func testHeadPushReadsOnlyTheHeadCommit() throws {
    let git = try repo.open()
    repo.addOrigin()
    commit("local")
    let local = repo.head()
    XCTAssertEqual(headPush(git)?.commit, local)
    XCTAssertEqual(headPush(git)?.isPushed, false)

    XCTAssertTrue(repo.git(["push", "-q"]).isSuccess)
    try repo.advanceOrigin(writing: "o.txt", "o\n")
    XCTAssertTrue(repo.git(["fetch", "-q"]).isSuccess)
    XCTAssertNotEqual(graph(git, limit: 1)?.commits.first?.oid, local, "前提: 先頭は upstream")
    XCTAssertEqual(headPush(git)?.commit, local)
    XCTAssertEqual(headPush(git)?.isPushed, true)

    let fresh = try TempGitRepo(initialCommit: false)
    XCTAssertNil(headPush(try fresh.open()))
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
