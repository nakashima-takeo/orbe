import OrbeTestSupport
import XCTest

@testable import Orbe

/// GitHub タブの問い合わせと書き込み（`GitHubCLI+OpenLists`）: 基点のディレクトリで gh が既定とする
/// リポジトリ、自分の login とレビュー依頼、自分を担当者・レビュアーに足す書き込み。PATH に偽の `gh` を置き、
/// 本物の子プロセスで測る。
///
/// 壊れると何が起きるか: fork の形で、gh が選ぶ本体ではなく別のリポジトリの一覧が出る。gh が無い・未認証が
/// 「見つからない」と言われ、直し方が分からない。「レビュー依頼」の札に、自分宛でない PR が入る・チーム宛が
/// 入らない。書き込みの応答を読み違え、GitHub が黙って捨てたアサインを成功と言う、または成功を失敗と言う。
final class GitHubCLIOpenListsTests: OrbeTestCase {
  private var dir: URL!
  private let repo = GitHubRepoName(nameWithOwner: "o/n")

  override func setUpWithError() throws {
    dir = TestScratch.caseDir
      .appendingPathComponent("orbe-gh-open-lists-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // 戻さない——`OrbeTestCase` が毎テスト `ShellPATH.shared` を張り直す。
    let path = dir.path
    ShellPATH.shared = ShellPATH(probe: { path })
  }

  /// 偽 `gh`。`auth token` は `authExit` で終わり、それ以外は `stdout` を出して `exit` で終わる。受けた
  /// 呼び出しの作業ディレクトリを `cwd.log` に残す。
  private func stageGh(stdout: String = "", exit: Int32 = 0, authExit: Int32 = 0) throws {
    let body = dir.appendingPathComponent("body.json").path
    try stdout.write(toFile: body, atomically: true, encoding: .utf8)
    let log = dir.appendingPathComponent("cwd.log").path
    let script = """
      #!/bin/sh
      if [ "$1" = "auth" ]; then exit \(authExit); fi
      pwd -P >> "\(log)"
      cat "\(body)"
      exit \(exit)
      """
    let gh = dir.appendingPathComponent("gh").path
    try script.write(toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
  }

  private func defaultRepository(root: String) -> Result<
    GitHubRepoName, GitHubRepositoryUnavailable
  >? {
    var answer: Result<GitHubRepoName, GitHubRepositoryUnavailable>?
    let done = expectation(description: "defaultRepository")
    GitHubCLI().defaultRepository(root: root) {
      answer = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    return answer
  }

  // MARK: - 既定のリポジトリ

  /// root で gh に既定のリポジトリを訊き、その正式名を返す（gh は作業ディレクトリの checkout から選ぶ）。
  func testDefaultRepositoryIsTheNameGhReportsInTheRoot() throws {
    try stageGh(
      stdout: #"{"nameWithOwner":"Upstream/Orbe","url":"https://github.com/Upstream/Orbe"}"#)
    let root = dir.appendingPathComponent("root")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    XCTAssertEqual(
      defaultRepository(root: root.path), .success(GitHubRepoName(nameWithOwner: "upstream/orbe")))
    let cwd = try String(contentsOf: dir.appendingPathComponent("cwd.log"), encoding: .utf8)
    XCTAssertTrue(
      cwd.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(root.path), "root で訊く: \(cwd)")
  }

  /// github.com 以外のホスト（GitHub Enterprise）のリポジトリは「見つからない」——以後の問い合わせと書き込みは
  /// github.com を名指しするので、同じ owner/name の別のリポジトリを読み書きしないため。ホストを確かめられない
  /// 答え（url が無い）も同じ。
  func testRepositoryOutsideGitHubDotComIsNotFound() throws {
    try stageGh(stdout: #"{"nameWithOwner":"o/n","url":"https://ghe.example.com/o/n"}"#)
    XCTAssertEqual(defaultRepository(root: dir.path), .failure(.notFound))

    try stageGh(stdout: #"{"nameWithOwner":"o/n"}"#)
    XCTAssertEqual(defaultRepository(root: dir.path), .failure(.notFound))
  }

  /// 使えない理由を分ける: 未認証・gh が既定のリポジトリを返さない（GitHub のリポジトリが無い・
  /// オフライン）。gh が無い場合は、PATH の既知の設置場所に本物の gh が居る手元では作れないので測らない。
  func testDefaultRepositoryTellsWhyItIsUnavailable() throws {
    try stageGh(stdout: #"{"nameWithOwner":"o/n","url":"https://github.com/o/n"}"#, authExit: 1)
    XCTAssertEqual(defaultRepository(root: dir.path), .failure(.ghUnauthed))

    try stageGh(stdout: "", exit: 1)
    XCTAssertEqual(defaultRepository(root: dir.path), .failure(.notFound))
  }

  // MARK: - 自分とレビュー依頼

  /// 自分（所属チームを含む）にレビューを頼んでいる open な PR を、github.com の検索 `review-requested:@me` で
  /// 先頭 100 件まで取る。
  func testReviewRequestQueryAsksGitHubDotComToSearchTheReviewRequests() throws {
    let arguments = GitHubCLI.reviewRequestsArguments(repo)

    XCTAssertTrue(
      zip(arguments, arguments.dropFirst()).contains { $0 == ("--hostname", "github.com") })
    let search = try XCTUnwrap(arguments.first { $0.hasPrefix("q=") }).dropFirst(2)
    XCTAssertEqual(
      Set(search.split(separator: " ")), ["repo:o/n", "is:pr", "is:open", "review-requested:@me"])
    XCTAssertTrue(try XCTUnwrap(arguments.first { $0.hasPrefix("query=") }).contains("first:100"))
  }

  /// PR でない検索結果（`{}`）は番号に入れない。失敗は nil。
  func testReviewRequestsAreReadFromTheResponse() throws {
    try stageGh(
      stdout: #"""
        {"data":{"viewer":{"login":"me"},"search":{"nodes":[{"number":12},{},{"number":7}]}}}
        """#)
    XCTAssertEqual(try reviewRequests(), GitHubReviewRequests(login: "me", numbers: [12, 7]))

    try stageGh(stdout: "", exit: 1)
    XCTAssertNil(try reviewRequests())
  }

  private func reviewRequests() throws -> GitHubReviewRequests? {
    var answer: GitHubReviewRequests??
    let done = expectation(description: "reviewRequests")
    GitHubCLI().reviewRequests(repo: repo) {
      answer = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    return try XCTUnwrap(answer, "答えが返らない")
  }

  // MARK: - 自分を足す書き込み

  /// 書き込みは github.com へ送り、自分の login は `-f`（文字列のまま）で渡す——`-F` は数字だけの login を
  /// 整数に変える。
  func testAddSelfWritesToGitHubDotComWithTheLoginAsAString() throws {
    let item = try XCTUnwrap(GitHubItemID(repo: "o/n", number: 221))
    for role in [GitHubSelfRole.assignee, .reviewer] {
      let arguments = GitHubCLI.addSelfArguments(as: role, to: item, login: "2048")

      XCTAssertTrue(
        zip(arguments, arguments.dropFirst()).contains { $0 == ("--hostname", "github.com") },
        "\(role)")
      let index = try XCTUnwrap(arguments.firstIndex { $0.hasSuffix("=2048") }, "\(role)")
      XCTAssertEqual(arguments[index - 1], "-f", "\(role)")
    }
  }

  /// 返すのは応答の担当者か個人宛のレビュー依頼の login（成否は呼び手が自分の有無で決める）。失敗は nil。
  func testAddSelfReturnsThePeopleInTheResponse() throws {
    try stageGh(stdout: #"{"number":221,"assignees":[{"login":"alice"},{"login":"me"}]}"#)
    XCTAssertEqual(try addSelf(.assignee), ["alice", "me"])

    try stageGh(stdout: #"{"number":221,"requested_reviewers":[{"login":"me"}]}"#)
    XCTAssertEqual(try addSelf(.reviewer), ["me"])

    try stageGh(stdout: "", exit: 1)
    XCTAssertNil(try addSelf(.assignee))
  }

  private func addSelf(_ role: GitHubSelfRole) throws -> [String]? {
    var answer: [String]??
    let done = expectation(description: "addSelf")
    GitHubCLI().addSelf(
      as: role, to: try XCTUnwrap(GitHubItemID(repo: "o/n", number: 221)), login: "me"
    ) {
      answer = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    return try XCTUnwrap(answer, "答えが返らない")
  }
}
