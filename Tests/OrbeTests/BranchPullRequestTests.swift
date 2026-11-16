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
  /// ブランチの PR の問い合わせを、`release` まで答えずに留めるか。
  private var holdsLookups = false
  private var held: [() -> Void] = []
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
        let answer = { [unowned self] in
          completion(
            GitHubBranchPullRequests(
              availability: .ready, ledger: GitHubRemoteLedger.Resolved(repositories: [:]),
              branches: answers[branch].map { [branch: $0] } ?? [:]))
        }
        if holdsLookups { held.append(answer) } else { answer() }
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

  /// Orbe の中のネット操作が終わったら、GitHub に問い直す。
  func testANetworkOperationInOrbeLooksUpAgain() throws {
    repo.addOrigin()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .unavailable(.notGitHub)
    let pullRequest = watch()
    pumpMain(until: { pullRequest.answer == .unavailable(.notGitHub) })
    SourceControl.shared(for: repo.root).fetch()
    pumpMain(until: { self.lookups.count == 2 }, timeout: 20, "フェッチの後に問い直す")
  }

  /// リモート追跡の ref が動いたとき、このブランチの push 先の追跡 ref が動いていれば問い直し、無関係なブランチの追跡 ref
  /// だけなら問い直さない。
  func testOnlyAMoveOfTheBranchsTrackingRefLooksUpAgain() throws {
    let refs = try trackedBranch()
    let pullRequest = watch()
    pumpMain(until: { pullRequest.answer == .unavailable(.notGitHub) })
    letTheLookUpSettle()

    try moveRemoteRef("refs/remotes/origin/other", to: refs.main, watchedBy: refs.recorder)
    letTheLookUpSettle()
    XCTAssertEqual(lookups, ["feat"], "無関係なブランチの追跡 ref では問い直さない")

    try moveRemoteRef("refs/remotes/origin/feat", to: refs.main, watchedBy: refs.recorder)
    pumpMain(until: { self.lookups.count == 2 }, "push 先の追跡 ref が動いたら問い直す")
  }

  /// PR のベースブランチだけが進んで両端が変わっても、手元の HEAD と PR の先頭が同じなら、手元とのずれは一致のまま。
  func testTheDriftStaysCountedWhenOnlyTheBaseMoves() throws {
    let pullRequest = try watchAnOpenPullRequest()
    pumpMain(until: { pullRequest.drift == .inSync }, "一致")
    let state = try XCTUnwrap(pullRequest.state)
    let advanced = repo.git(["commit-tree", "main^{tree}", "-p", "main", "-m", "base"]).stdoutText
      .trimmingCharacters(in: .newlines)
    XCTAssertTrue(repo.git(["update-ref", "refs/heads/main", advanced]).isSuccess)
    content = pullRequestContent(base: advanced)
    state.reload()
    pumpMain(
      until: {
        if case .ready(let ends, _) = state.bounds { ends.base == advanced } else { false }
      },
      "新しいベースで両端が揃う")
    XCTExpectFailure("両端を求め直す間にずれを消し、同じ先頭で揃い直したときに数えた組が同じとして数え直さない") {
      XCTAssertEqual(pullRequest.drift, .inSync)
    }
  }

  /// GitHub に問い合わせている間にブランチを切り替えたら、前のブランチの答えを出さず、読んでいる状態になる。
  func testSwitchingTheBranchWhileReadingDropsTheOldAnswerAtOnce() throws {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .unavailable(.notGitHub)
    answers["other"] = .unavailable(.unverified)
    let pullRequest = watch()
    pumpMain(until: { pullRequest.answer == .unavailable(.notGitHub) })
    holdsLookups = true
    pullRequest.reload()
    pumpMain(until: { self.held.count == 1 }, "前提: 問い合わせの最中")

    XCTAssertTrue(repo.git(["switch", "-q", "-c", "other"]).isSuccess)
    let files = RootFiles.shared(for: repo.root)
    pumpMain(until: { files.status?.branch?.name == "other" }, "前提: 切り替えを知る")
    XCTExpectFailure("問い合わせの最中は読み直しを積むだけで、読んでいる状態に戻さない") {
      XCTAssertEqual(pullRequest.answer, .reading)
    }

    holdsLookups = false
    release()
    pumpMain(until: { pullRequest.answer == .unavailable(.unverified) }, "新しいブランチの答え")
  }

  /// GitHub に問い合わせている間に push 先の追跡 ref が動いたら、その問い合わせが終わった後に問い直す。
  func testATrackingRefMoveWhileReadingLooksUpAgainAfterwards() throws {
    let refs = try trackedBranch()
    let pullRequest = watch()
    pumpMain(until: { pullRequest.answer == .unavailable(.notGitHub) })
    letTheLookUpSettle()
    holdsLookups = true
    pullRequest.reload()
    pumpMain(until: { self.held.count == 1 }, "前提: 問い合わせの最中")

    try moveRemoteRef("refs/remotes/origin/feat", to: refs.main, watchedBy: refs.recorder)
    holdsLookups = false
    release()
    letTheLookUpSettle()
    XCTExpectFailure("問い合わせの最中に届いた追跡 ref の知らせを捨て、終わった後の値を次に比べる相手にする") {
      XCTAssertEqual(lookups.count, 3, "最初・最中・終わった後")
    }
  }

  // MARK: - ヘルパ

  /// 留めた問い合わせに答える。
  private func release() {
    let answers = held
    held = []
    for answer in answers { answer() }
  }

  /// 問い合わせの後の、追跡 ref の値を覚える git の読み取りが終わるまで main を回す（終わったことは外から見えない）。
  private func letTheLookUpSettle() {
    let until = Date().addingTimeInterval(1)
    while Date() < until {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  /// origin に送って upstream を付けたブランチ feat（main より 1 コミット先）。根のサービスのリモート追跡の ref の知らせを
  /// 数える観測者を付ける。
  private func trackedBranch() throws -> (main: String, recorder: RemoteRefsRecorder) {
    repo.addOrigin()
    let main = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "b"]).isSuccess)
    XCTAssertTrue(repo.git(["push", "-q", "-u", "origin", "feat"]).isSuccess)
    answers["feat"] = .unavailable(.notGitHub)
    let recorder = RemoteRefsRecorder()
    let files = RootFiles.shared(for: repo.root)
    files.addObserver(recorder)
    addTeardownBlock { @MainActor in files.removeObserver(recorder) }
    return (main, recorder)
  }

  /// リモート追跡の ref `ref` を `commit` に動かし、根のサービスがそれを知らせるまで待つ。
  private func moveRemoteRef(
    _ ref: String, to commit: String, watchedBy recorder: RemoteRefsRecorder
  )
    throws
  {
    let before = recorder.moves
    XCTAssertTrue(repo.git(["update-ref", ref, commit]).isSuccess)
    pumpMain(until: { recorder.moves > before }, "前提: リモート追跡の ref が動いたと知らせる")
  }

  /// ブランチ feat から出ている open の PR 9 を見る（中身の両端は `pullRequestContent`）。
  private func watchAnOpenPullRequest() throws -> BranchPullRequest {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "b"]).isSuccess)
    let base = repo.git(["rev-parse", "main"]).stdoutText.trimmingCharacters(in: .newlines)
    content = pullRequestContent(base: base)
    answers["feat"] = .gitHub(
      GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([pr(9, state: "OPEN")]))
    return watch()
  }

  /// PR 9 の中身。先頭は今の HEAD。
  private func pullRequestContent(base: String) -> GitHubPullRequestContent {
    GitHubPullRequestContent(
      nodeID: "PR_1", number: 9, title: "題", url: "https://github.com/me/r/pull/9", isDraft: false,
      state: .open, body: "", author: "me", baseRefName: "main", headRefName: "feat",
      baseCommit: base, headCommit: repo.head(), commitCount: 1, commits: [], files: [])
  }
}

/// 根のサービスの、リモート追跡の ref が動いたという知らせを数える。
@MainActor
private final class RemoteRefsRecorder: RootFilesObserver {
  var moves = 0
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {}
  func rootFilesStatusDidChange(_ files: RootFiles) {}
  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {}
  func rootFilesGitStateDidChange(_ files: RootFiles, remoteRefsChanged: Bool) {
    if remoteRefsChanged { moves += 1 }
  }
}
