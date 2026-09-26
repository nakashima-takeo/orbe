import XCTest

@testable import Orbe

/// remote の URL と GitHub の答え（`nameWithOwner`）を、同じリポジトリなら等しい名前へ読む口
/// （`GitHubRepoName`）。
///
/// ここが破れると、行と PR の同一性がそもそも立たない——読めない形の origin を持つリポジトリでは
/// 番号チップが 1 つも付かず、PR 行はすべてブラウザ行になり、clean は PR の事実を 1 つも持てない。
/// 大小文字で割れると、同じリポジトリの PR が別のリポジトリのものとして弾かれる。
final class GitHubRepoNameTests: OrbeTestCase {

  /// git が remote に書く GitHub の URL の形（https・資格情報つき・scp 形式・SSH のホスト別名・
  /// ssh:// のポートつき・443 番の SSH）は、どれも `owner/name` に読める。
  func testGitHubRemoteURLFormsReadAsOwnerAndName() {
    let forms = [
      "https://github.com/o/r",
      "https://github.com/o/r.git",
      "https://github.com/o/r/",
      "https://user@github.com/o/r",
      "git@github.com:o/r",
      "git@github.com:o/r.git",
      "git@github.com-work:o/r.git",
      "ssh://git@github.com/o/r.git",
      "ssh://git@github.com:22/o/r.git",
      "ssh://git@ssh.github.com:443/o/r.git",
    ]
    for url in forms {
      XCTAssertEqual(
        GitHubRepoName(remoteURL: url), GitHubRepoName(nameWithOwner: "o/r"), "\(url) を o/r と読む")
    }
  }

  /// GitHub でない remote と、リポジトリを指していない URL は名前を持たない（どの PR とも等しくならない）。
  func testNonGitHubOrIncompleteURLHasNoName() {
    for url in [
      "https://gitlab.com/o/r.git", "git@bitbucket.org:o/r.git", "/tmp/origin.git",
      "https://github.com/o", "https://github.com/",
    ] {
      XCTAssertNil(GitHubRepoName(remoteURL: url), "\(url) は GitHub のリポジトリ名にならない")
    }
  }

  /// GitHub の名前は大小文字を区別しないので、URL の綴りと GitHub の答えの綴りが違っても同じリポジトリ。
  func testNamesFromURLAndFromGitHubAreEqualRegardlessOfCase() throws {
    let answered = GitHubRepoName(nameWithOwner: "Owner/Repo")
    XCTAssertEqual(GitHubRepoName(remoteURL: "git@github.com:OWNER/repo.git"), answered)
    XCTAssertEqual(GitHubRepoName(owner: "owner", name: "REPO"), answered)
  }
}
