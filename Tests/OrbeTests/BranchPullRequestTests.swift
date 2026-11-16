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
  var repo: TempGitRepo!
  var lookups: [String] = []
  var answers: [String: GitHubBranchPullRequests.Branch] = [:]
  var exists: Result<Bool, GitHubFailure> = .success(true)
  var content: GitHubPullRequestContent?
  /// PR の中身を問い合わせた回数。
  var contentReads = 0
  /// ブランチの PR の問い合わせを、`release` まで答えずに留めるか。
  var holdsLookups = false
  /// 台帳の remote → GitHub のリポジトリ（PR のコミットを取りに行く remote と、PR のベースブランチの追跡 ref を決める）。
  var repositories: [String: GitHubRemoteRepository] = [:]
  var held: [() -> Void] = []
  /// ブランチが GitHub に在るかを問い合わせたブランチ。
  var publishedChecks: [GitHubBranchRef] = []
  /// ブランチが GitHub に在るかの問い合わせを、答えずに留めるか（留めた問い合わせは `heldChecks` が順に持つ）。
  var holdsPublishedChecks = false
  var heldChecks: [(Result<Bool, GitHubFailure>) -> Void] = []
  let me = GitHubRepoName(nameWithOwner: "me/r")

  override func setUpWithError() throws {
    repo = try TempGitRepo()
    lookups = []
    answers = [:]
  }

  var source: PullRequestSource {
    PullRequestSource(
      branchPullRequests: { [unowned self] _, branch, completion in
        lookups.append(branch)
        let answer = { [unowned self] in
          completion(
            GitHubBranchPullRequests(
              availability: .ready, ledger: GitHubRemoteLedger.Resolved(repositories: repositories),
              branches: answers[branch].map { [branch: $0] } ?? [:]))
        }
        if holdsLookups { held.append(answer) } else { answer() }
      },
      branchExists: { [unowned self] ref, completion in
        publishedChecks.append(ref)
        if holdsPublishedChecks { heldChecks.append(completion) } else { completion(exists) }
      },
      content: { [unowned self] _, completion in
        contentReads += 1
        completion(content.map { .success($0) } ?? .failure(.reason("")))
      },
      setViewed: { _, _, _, _ in })
  }

  func watch() -> BranchPullRequest {
    let pullRequest = BranchPullRequest.shared(for: repo.root, source: source)
    pullRequest.beginWatching()
    addTeardownBlock { @MainActor in pullRequest.endWatching() }
    return pullRequest
  }

  func pr(_ number: Int, state: String) -> GitHubBranchPR {
    GitHubBranchPR(
      number: number, headRefName: "feat", state: state, baseRefName: "main", headRepository: me,
      url: "https://github.com/me/r/pull/\(number)")
  }

  func settled(_ pullRequest: BranchPullRequest) {
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

  /// ブランチが GitHub に在るかを確かめられなかったときは、「無い」と読まない（作成の入口を塞がない）。
  func testAFailedPublishedCheckIsNotReadAsUnpublished() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .gitHub(GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([]))
    exists = .failure(.unreachable)
    let pullRequest = watch()
    pumpMain(
      until: {
        if case .noPullRequest(let creation) = pullRequest.answer {
          return creation.published == .unknown
        }
        return false
      }, "確かめられない")
  }

  /// fork のブランチから親へ出した PR のコミットは、親のリポジトリを指す remote から取ってくる。取ってきた後に、手元と
  /// のずれを数える。
  func testAForkPullRequestsCommitsAreFetchedFromTheParentsRemote() throws {
    let parent = GitHubRepoName(nameWithOwner: "up/r")
    repo.addOrigin()
    let main = repo.head()
    let parentBare = repo.dir.path + "-upstream.git"
    let other = repo.dir.path + "-parent-clone"
    for args in [
      ["init", "-q", "--bare", "-b", "main", parentBare],
      ["remote", "add", "upstream", parentBare],
      ["push", "-q", "upstream", "main"], ["clone", "-q", parentBare, other],
      [
        "-C", other, "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "--allow-empty",
        "-m", "pr",
      ],
      ["-C", other, "push", "-q", "origin", "HEAD:refs/heads/pr"],
    ] {
      XCTAssertTrue(repo.git(args).isSuccess, "\(args)")
    }
    let head = repo.git(["-C", other, "rev-parse", "HEAD"]).stdoutText
      .trimmingCharacters(in: .newlines)
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "b"]).isSuccess)
    repositories = ["origin": .github(me), "upstream": .github(parent)]
    content = GitHubPullRequestContent(
      nodeID: "PR_1", number: 9, title: "題", url: "https://github.com/up/r/pull/9", isDraft: false,
      state: .open, body: "", author: "me", baseRefName: "main", headRefName: "feat",
      baseCommit: main, headCommit: head, commitCount: 1, commits: [], files: [])
    answers["feat"] = .gitHub(
      GitHubBranchRef(repo: me, branch: "feat"),
      pullRequests: .success([
        GitHubBranchPR(
          number: 9, headRefName: "feat", state: "OPEN", baseRefName: "main", headRepository: me,
          url: "https://github.com/up/r/pull/9")
      ]))

    let pullRequest = watch()

    pumpMain(
      until: {
        if case .ready? = pullRequest.state?.bounds { true } else { false }
      }, "親の remote から取って両端が揃う")
    pumpMain(
      until: { pullRequest.drift == .diverged(ahead: 1, behind: 1) }, "取ってきた後に数える")
  }

  // MARK: - ヘルパ

  /// ブランチ feat から出ている open の PR 9 を見る（中身の両端は `pullRequestContent`）。
  func watchAnOpenPullRequest(head: String = "HEAD") throws -> BranchPullRequest {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "b"]).isSuccess)
    let base = repo.git(["rev-parse", "main"]).stdoutText.trimmingCharacters(in: .newlines)
    content = pullRequestContent(base: base, head: head)
    answers["feat"] = .gitHub(
      GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([pr(9, state: "OPEN")]))
    return watch()
  }

  /// PR 9 の中身。先頭は `head`（リビジョン。既定は今の HEAD）のコミット。
  func pullRequestContent(base: String, head: String = "HEAD") -> GitHubPullRequestContent {
    let headCommit = repo.git(["rev-parse", head]).stdoutText.trimmingCharacters(in: .newlines)
    return GitHubPullRequestContent(
      nodeID: "PR_1", number: 9, title: "題", url: "https://github.com/me/r/pull/9", isDraft: false,
      state: .open, body: "", author: "me", baseRefName: "main", headRefName: "feat",
      baseCommit: base, headCommit: headCommit, commitCount: 1, commits: [], files: [])
  }
}
