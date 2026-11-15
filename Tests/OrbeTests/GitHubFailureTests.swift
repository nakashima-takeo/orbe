import XCTest

@testable import Orbe

/// gh の失敗の分類（`GitHubFailure`）。
///
/// 壊れると何が起きるか: 未ログイン・レート制限・ネット不通が「それ以外」に分類されて、定型の案内メッセージの代わりに gh の英語の
/// メッセージがそのまま出る。逆に、ほかの失敗が未ログインなどに誤分類されると、直し方の違う案内が出る。メッセージの字面は gh 2.104.0 で確かめたもの。
final class GitHubFailureTests: OrbeTestCase {
  private func classify(_ status: Int32 = 1, stderr: String, stdout: String = "")
    -> GitHubFailure
  {
    GitHubFailure.of(status: status, stderr: stderr, stdout: Data(stdout.utf8))
  }

  func testAuthenticationRequiredIsUnauthenticated() {
    XCTAssertEqual(
      classify(
        4,
        stderr: "To get started with GitHub CLI, please run:  gh auth login\n"
          + "Alternatively, populate the GH_TOKEN environment variable with a GitHub API "
          + "authentication token.\n"),
      .unauthenticated, "認証情報が無い（終了コード 4）")
    XCTAssertEqual(
      classify(stderr: "gh: Bad credentials (HTTP 401)\nTry authenticating with:  gh auth login\n"),
      .unauthenticated, "認証情報が拒まれた")
  }

  func testRateLimitIsReadFromTheGraphQLErrorTypeAndTheMessage() {
    XCTAssertEqual(
      classify(
        stderr: "gh: x\n",
        stdout: #"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"x"}]}"#
      ),
      .rateLimited, "GraphQL の errors の種類")
    XCTAssertEqual(
      classify(stderr: "gh: You have exceeded a secondary rate limit. (HTTP 403)\n"), .rateLimited,
      "secondary rate limit")
  }

  func testConnectionFailuresAreUnreachable() {
    XCTAssertEqual(
      classify(
        stderr: "error connecting to api.github.com\n"
          + "check your internet connection or https://githubstatus.com\n"),
      .unreachable, "名前解決の失敗")
    XCTAssertEqual(
      classify(
        stderr: #"Post "https://api.github.com/graphql": proxyconnect tcp: dial tcp "#
          + "127.0.0.1:9: connect: connection refused\n"),
      .unreachable, "接続の失敗")
  }

  /// それ以外は gh のエラーメッセージの要点（`gh:` などで始まる行）を持つ。要点の行が無ければ最後の行、何も無ければ空。
  func testOtherFailuresKeepTheGist() {
    XCTAssertEqual(
      classify(stderr: "gh: Could not resolve to a PullRequest with the number of 9.\n"),
      .reason("gh: Could not resolve to a PullRequest with the number of 9."))
    XCTAssertEqual(
      classify(stderr: "warning: x\nGraphQL: Something went wrong (pullRequest)\n"),
      .reason("GraphQL: Something went wrong (pullRequest)"))
    XCTAssertEqual(classify(stderr: "first\nlast\n"), .reason("last"))
    XCTAssertEqual(classify(stderr: ""), .reason(""))
  }
}
