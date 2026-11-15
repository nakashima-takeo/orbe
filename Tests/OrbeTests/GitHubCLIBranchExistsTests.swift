import OrbeTestSupport
import XCTest

@testable import Orbe

/// ブランチが GitHub に在るかの問い合わせ（`GitHubCLI.branchExists`）。PR の作成の入口は、「無い」と分かったときだけ押せない
/// 状態になる。
///
/// 壊れると何が起きるか: push 済みのブランチで作成の入口が塞がる（失敗や見えないリポジトリを「無い」と読む）。未公開の
/// ブランチで、空の作成ページを開く入口が出る（「無い」を「在る」と読む）。ブランチ名が、ブランチの外の ref（タグなど）の名前として渡る。
final class GitHubCLIBranchExistsTests: OrbeTestCase {
  private let ref = GitHubBranchRef(
    repo: GitHubRepoName(nameWithOwner: "o/2048"), branch: "feat/a")

  /// owner・name・ref の名前は文字列のまま（`-f`）渡し、ref はブランチの完全な名前（`refs/heads/`）で名指しする。
  func testQueryPassesTheFullBranchNameAsStrings() throws {
    let arguments = GitHubCLI.branchExistsArguments(ref)
    XCTAssertEqual(Array(arguments.prefix(4)), ["api", "graphql", "--hostname", "github.com"])
    for field in ["o=o", "n=2048", "q=refs/heads/feat/a"] {
      let index = try XCTUnwrap(arguments.firstIndex(of: field), "\(field) を渡す")
      XCTAssertEqual(arguments[index - 1], "-f", "\(field) は文字列として渡す")
    }
  }

  func testABranchOnGitHubExists() throws {
    try stageGh(stdout: #"{"data":{"repository":{"ref":{"name":"feat/a"}}}}"#, exit: 0)
    XCTAssertEqual(try branchExists(), .success(true))
  }

  func testABranchNotOnGitHubDoesNotExist() throws {
    try stageGh(stdout: #"{"data":{"repository":{"ref":null}}}"#, exit: 0)
    XCTAssertEqual(try branchExists(), .success(false))
  }

  /// 見えないリポジトリは、ブランチの有無を確かめられないので「無い」ではなく失敗。
  func testAnUnseenRepositoryIsAFailure() throws {
    try stageGh(
      stdout: """
        {"data":{"repository":null},"errors":[{"type":"NOT_FOUND","path":["repository"],\
        "message":"Could not resolve to a Repository with the name 'o/2048'."}]}
        """, exit: 1,
      stderr: "gh: Could not resolve to a Repository with the name 'o/2048'.\n")
    guard case .failure = try branchExists() else { return XCTFail("失敗として返る") }
  }

  // MARK: - ヘルパ

  /// 決まった出力と終了コードを返す偽 `gh` を PATH に置く。
  private func stageGh(stdout: String, exit: Int32, stderr: String = "") throws {
    let dir = TestScratch.caseDir.appendingPathComponent("orbe-gh-branch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let body = dir.appendingPathComponent("body.json").path
    try stdout.write(toFile: body, atomically: true, encoding: .utf8)
    let err = dir.appendingPathComponent("stderr.txt").path
    try stderr.write(toFile: err, atomically: true, encoding: .utf8)
    let gh = dir.appendingPathComponent("gh").path
    try "#!/bin/sh\ncat \"\(body)\"\ncat \"\(err)\" >&2\nexit \(exit)\n".write(
      toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
    let path = dir.path
    ShellPATH.shared = ShellPATH(probe: { "\(path):/usr/bin:/bin" })
  }

  private func branchExists() throws -> Result<Bool, GitHubFailure> {
    var answer: Result<Bool, GitHubFailure>?
    let done = expectation(description: "branchExists")
    GitHubCLI().branchExists(ref) {
      answer = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    return try XCTUnwrap(answer, "答えが返らない")
  }
}
