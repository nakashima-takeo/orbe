import XCTest

@testable import Orbe

/// PR の head（どのリポジトリのどのブランチか）を、gh の出力から読む口（`GitHubBranchPR` /
/// `GitHubPullRequest` の decode）。
///
/// ここが破れると、古い gh（`gh pr list --json headRepository` に `nameWithOwner` が無い・空文字）の利用者
/// だけ、clean がブランチの PR を 1 件も持てない——全行が取得失敗で安全群が常に空になるか、どの行とも
/// 等しくない head として弾かれて「確かめて 0 件」と読み、レビュー中の worktree が安全群に入る。どちらも
/// 今の gh の出力を返す偽 gh では再現しない。
final class GitHubPullRequestHeadTests: OrbeTestCase {

  private let feat = GitHubBranchRef(repo: GitHubRepoName(nameWithOwner: "me/r"), branch: "feat")

  private func branchPR(headRepository: String, owner: String) throws -> GitHubBranchPR {
    let json =
      #"{"number":1,"headRefName":"feat","state":"OPEN","baseRefName":"main","#
      + #""headRepository":\#(headRepository),"headRepositoryOwner":\#(owner)}"#
    return try JSONDecoder().decode(GitHubBranchPR.self, from: Data(json.utf8))
  }

  /// `gh pr list --json` の head は、どの版の出力でも owner と名前から同じリポジトリに読む。
  func testBranchPRHeadIsTheSameAcrossGhVersions() throws {
    let owner = #"{"id":"U_1","login":"me"}"#
    let outputs = [
      ("v2.79 以前（nameWithOwner のキーが無い）", #"{"id":"R_1","name":"r"}"#),
      ("v2.80〜2.88（nameWithOwner が空文字）", #"{"id":"R_1","name":"r","nameWithOwner":""}"#),
      ("v2.89 以降", #"{"id":"R_1","name":"r","nameWithOwner":"me/r"}"#),
    ]
    for (label, repository) in outputs {
      XCTAssertEqual(try branchPR(headRepository: repository, owner: owner).head, feat, label)
    }
  }

  /// head のリポジトリが消えた PR（削除された fork）は head を持たず、どの行とも等しくならない。
  func testBranchPRWithoutAHeadRepositoryHasNoHead() throws {
    XCTAssertNil(try branchPR(headRepository: "null", owner: "null").head)
    XCTAssertNil(
      try branchPR(headRepository: #"{"id":"","name":""}"#, owner: #"{"id":"","login":""}"#).head,
      "gh が空の値で埋めて返す形")
  }

  /// open 一覧（GraphQL）の PR も、同じ owner と名前から head を読む。
  func testOpenListPullRequestHeadIsReadFromOwnerAndName() throws {
    func decode(_ head: String) throws -> GitHubPullRequest {
      let json =
        #"{"number":1,"title":"t","headRefName":"feat",\#(head),"reviewDecision":null}"#
      return try JSONDecoder().decode(GitHubPullRequest.self, from: Data(json.utf8))
    }
    XCTAssertEqual(
      try decode(#""headRepositoryOwner":{"login":"Me"},"headRepository":{"name":"R"}"#).head, feat,
      "大小文字は区別しない")
    XCTAssertNil(
      try decode(#""headRepositoryOwner":null,"headRepository":null"#).head,
      "head のリポジトリが消えた PR")
  }
}
