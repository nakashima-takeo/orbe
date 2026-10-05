import XCTest

@testable import Orbe

/// remote の URL と GitHub の答え（`nameWithOwner`）を、同じリポジトリなら等しい名前へ読む口
/// （`GitHubRepoName`）。
///
/// ここが破れると、行と PR の同一性がそもそも立たない——読めない形の origin を持つリポジトリでは
/// clean は PR の事実を 1 つも持てない。
/// 大小文字で割れると、同じリポジトリの PR が別のリポジトリのものとして弾かれる。github.com かどうかを
/// ホストで決めないと、GitHub Enterprise（github.company.com）の owner/name で github.com を読み書きする。
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
  func testNamesFromURLAndFromGitHubAreEqualRegardlessOfCase() {
    let answered = GitHubRepoName(nameWithOwner: "Owner/Repo")
    XCTAssertEqual(GitHubRepoName(remoteURL: "git@github.com:OWNER/repo.git"), answered)
    XCTAssertEqual(GitHubRepoName(owner: "owner", name: "REPO"), answered)
  }

  // MARK: - github.com か

  /// github.com・ssh.github.com（443 番の SSH）・SSH の書き方での `github.com-` で始まる別名と `.github.com` で
  /// 終わる別名だけが github.com。
  /// ホスト名の大小文字は問わない。
  func testGitHubDotComHostsAreGitHub() {
    for url in [
      "https://github.com/o/r",
      "https://user@github.com/o/r",
      "git@github.com:o/r.git",
      "ssh://git@github.com:22/o/r.git",
      "ssh://git@ssh.github.com:443/o/r.git",
      "git@github.com-work:o/r.git",
      "git@work.github.com:o/r.git",
      "ssh://git@work.github.com/o/r.git",
      "HTTPS://GitHub.COM/o/r",
    ] {
      XCTAssertTrue(GitHubRepoName.isGitHub(remoteURL: url), "\(url) は github.com")
    }
  }

  /// ホストが github.com でなければ、URL のどこかに github.com を含んでも github.com ではない（GitHub
  /// Enterprise・github.com で始まる別のドメイン・https の別名・ローカルのパス）。
  func testOtherHostsAndLocalPathsAreNotGitHub() {
    for url in [
      "https://github.company.com/o/n",
      "git@github.company.com:o/n.git",
      "ssh://git@github.company.com/o/n.git",
      "ssh://git@github.company.com:22/o/n.git",
      "https://github.com.evil.example/o/n",
      "https://github.com-work/o/n",
      "https://work.github.com/o/n",
      "/tmp/github.com/o/r.git",
    ] {
      XCTAssertFalse(GitHubRepoName.isGitHub(remoteURL: url), "\(url) は github.com ではない")
    }
  }
}
