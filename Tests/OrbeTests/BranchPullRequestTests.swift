import XCTest

@testable import Orbe

/// worktree の今の PR（`BranchPullRequest`）——今のブランチの open の PR、無いときの作成の入口、出せない理由、手元とのずれ。
/// GitHub は差し替えの構造体が答え、git は一時リポジトリで実際に問う。
///
/// 壊れると何が起きるか: main や detached でも GitHub に問い合わせる。閉じた PR しか無いブランチで PR のパネルが出る。
/// 未公開と確かめていないのに作成の入口が塞がる。ブランチを切り替えた後も前のブランチの PR が出る。手元が PR の先頭と
/// 同じなのに「未取得のコミット」と出る。
@MainActor
final class BranchPullRequestTests: OrbeTestCase {
  private var repo: TempGitRepo!
  private var lookups: [String] = []
  private var answers: [String: GitHubBranchPullRequests.Branch] = [:]
  private var exists: Result<Bool, GitHubFailure> = .success(true)
  private var content: GitHubPullRequestContent?
  private let me = GitHubRepoName(nameWithOwner: "me/r")

  override func setUpWithError() throws {
    repo = try TempGitRepo()
    lookups = []
    answers = [:]
  }

  private var source: PullRequestSource {
    PullRequestSource(
      branchPullRequests: { [unowned self] _, branch, completion in
        lookups.append(branch)
        completion(
          GitHubBranchPullRequests(
            availability: .ready, ledger: GitHubRemoteLedger.Resolved(repositories: [:]),
            branches: answers[branch].map { [branch: $0] } ?? [:]))
      },
      branchExists: { [unowned self] _, completion in completion(exists) },
      content: { [unowned self] _, completion in
        completion(content.map { .success($0) } ?? .failure(.reason("")))
      },
      setViewed: { _, _, _, _ in })
  }

  private func watch() -> BranchPullRequest {
    let pullRequest = BranchPullRequest.shared(for: repo.root, source: source)
    pullRequest.beginWatching()
    addTeardownBlock { @MainActor in pullRequest.endWatching() }
    return pullRequest
  }

  private func pr(_ number: Int, state: String) -> GitHubBranchPR {
    GitHubBranchPR(
      number: number, headRefName: "feat", state: state, baseRefName: "main", headRepository: me,
      url: "https://github.com/me/r/pull/\(number)")
  }

  private func settled(_ pullRequest: BranchPullRequest) {
    pumpMain(until: { pullRequest.answer != .reading }, "答えが出る")
  }

  /// 既定のブランチに居る worktree と、どのブランチにも居ない worktree では GitHub に問い合わせず、理由だけを出す。
  func testTheDefaultBranchAndDetachedHeadAreNotAsked() {
    let pullRequest = watch()
    settled(pullRequest)
    XCTAssertEqual(pullRequest.answer, .unavailable(.defaultBranch))

    XCTAssertTrue(repo.git(["switch", "-q", "--detach"]).isSuccess)
    pumpMain(until: { pullRequest.answer == .unavailable(.detached) }, "ブランチに居ない")
    XCTAssertEqual(lookups, [])
  }

  /// open の PR が無ければ（閉じた PR だけでも）、答えは作成の入口の材料になる。公開済みかは、ブランチが GitHub に無いと
  /// 確かめられたときだけ「無い」になる。
  func testWithoutAnOpenPullRequestTheCreationEntryAsksWhetherTheBranchIsPublished() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    let ref = GitHubBranchRef(repo: me, branch: "feat")
    answers["feat"] = .gitHub(ref, pullRequests: .success([pr(3, state: "CLOSED")]))
    exists = .success(false)
    let pullRequest = watch()
    pumpMain(
      until: {
        if case .noPullRequest(let creation) = pullRequest.answer {
          return creation.published == .no
        }
        return false
      }, "未公開と分かる")
    guard case .noPullRequest(let creation) = pullRequest.answer else {
      return XCTFail("作成の入口の材料")
    }
    XCTAssertEqual(creation.branch, "feat")
    XCTAssertEqual(creation.defaultBranch, "main")
    XCTAssertEqual(creation.url, ref.pullRequestCreationURL)
  }

  /// open の最新の PR を、その PR の PR ごとの状態（`PullRequestState`）で答え、中身を読む。手元の HEAD が PR の先頭と同じなら一致とする。
  func testAnOpenPullRequestIsReadAndTheDriftIsCounted() throws {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "b"]).isSuccess)
    let base = repo.git(["rev-parse", "main"]).stdoutText.trimmingCharacters(in: .newlines)
    content = GitHubPullRequestContent(
      nodeID: "PR_1", number: 9, title: "題", url: "https://github.com/me/r/pull/9", isDraft: false,
      state: .open, body: "", author: "me", baseRefName: "main", headRefName: "feat",
      baseCommit: base, headCommit: repo.head(), commitCount: 1, commits: [], files: [])
    answers["feat"] = .gitHub(
      GitHubBranchRef(repo: me, branch: "feat"),
      pullRequests: .success([pr(9, state: "OPEN"), pr(4, state: "OPEN")]))
    let pullRequest = watch()
    pumpMain(until: { pullRequest.drift == .inSync }, "一致")
    XCTAssertEqual(pullRequest.state?.key.id.number, 9, "open の最新")
    XCTAssertEqual(pullRequest.state?.content?.title, "題")

    try repo.write("c.txt", "c\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "c"]).isSuccess)
    pumpMain(
      until: { pullRequest.drift == .diverged(ahead: 1, behind: 0) }, "未 push のコミットを数える")
    XCTAssertEqual(lookups, ["feat"], "HEAD が動いただけなら GitHub に問い合わせない")
  }

  /// ブランチを切り替えたら GitHub に問い直し、前のブランチの答えは出さない。
  func testSwitchingTheBranchLooksUpTheNewBranch() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .unavailable(.notGitHub)
    answers["other"] = .unavailable(.unverified)
    let pullRequest = watch()
    pumpMain(until: { pullRequest.answer == .unavailable(.notGitHub) })
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "other"]).isSuccess)
    pumpMain(until: { pullRequest.answer == .unavailable(.unverified) }, "新しいブランチの答え")
    XCTAssertEqual(lookups, ["feat", "other"])
  }
}
