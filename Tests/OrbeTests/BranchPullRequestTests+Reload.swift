import OrbeTestSupport
import XCTest

@testable import Orbe

/// worktree の今の PR を GitHub に問い直すきっかけ——Orbe の中のネット操作の終わり、push 先と PR のベースブランチの追跡
/// ref の動き、ブランチの切り替え、問い合わせの最中に来たきっかけ、見ている者の出入り。
///
/// 壊れると何が起きるか: 端末やほかの所での push の後も古い PR のまま。無関係なブランチの fetch のたびに GitHub へ問い合わせる。
/// ブランチを切り替えた直後に前のブランチの PR が出る。detached から戻ると「ブランチに居ない」のまま止まる。面やタブを
/// 開くたびに GitHub へ問い合わせる。見ていない PR を問い合わせ続ける。
extension BranchPullRequestTests {
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

    try moveRemoteRef("refs/remotes/origin/other", to: refs.main, watchedBy: refs.recorder)
    XCTAssertTrue(
      holds(for: 1) { self.lookups == ["feat"] }, "無関係なブランチの追跡 ref では問い直さない")

    try moveRemoteRef("refs/remotes/origin/feat", to: refs.main, watchedBy: refs.recorder)
    pumpMain(until: { self.lookups.count == 2 }, "push 先の追跡 ref が動いたら問い直す")
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
    XCTAssertEqual(pullRequest.answer, .reading)

    holdsLookups = false
    releaseLookups()
    pumpMain(until: { pullRequest.answer == .unavailable(.unverified) }, "新しいブランチの答え")
  }

  /// GitHub に問い合わせている間（最初の問い合わせも）に push 先の追跡 ref が動いたら、その問い合わせが終わった後に 1 回
  /// だけ問い直す。
  func testATrackingRefMoveWhileReadingLooksUpAgainAfterwards() throws {
    let refs = try trackedBranch()
    holdsLookups = true
    _ = watch()
    pumpMain(until: { self.held.count == 1 }, "前提: 最初の問い合わせの最中")

    try moveRemoteRef("refs/remotes/origin/feat", to: refs.main, watchedBy: refs.recorder)
    XCTAssertTrue(holds(for: 1) { self.lookups.count == 1 }, "前提: 問い合わせの最中は問い直さない")
    holdsLookups = false
    releaseLookups()
    pumpMain(until: { self.lookups.count == 2 }, "終わった後に問い直す")
    XCTAssertTrue(holds(for: 1) { self.lookups.count == 2 }, "1 回だけ")
  }

  /// どのブランチにも居ない状態から同じブランチに戻ったら、GitHub に問い直す（「ブランチに居ない」のまま止まらない）。
  func testComingBackToTheSameBranchFromADetachedHeadLooksUpAgain() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .unavailable(.notGitHub)
    let pullRequest = watch()
    pumpMain(until: { pullRequest.answer == .unavailable(.notGitHub) })
    XCTAssertTrue(repo.git(["switch", "-q", "--detach"]).isSuccess)
    pumpMain(until: { pullRequest.answer == .unavailable(.detached) }, "ブランチに居ない")

    XCTAssertTrue(repo.git(["switch", "-q", "feat"]).isSuccess)
    pumpMain(until: { pullRequest.answer == .unavailable(.notGitHub) }, "戻ったブランチの答え")
    XCTAssertEqual(lookups, ["feat", "feat"])
  }

  /// 見ている者が増えただけでは問い直さない（誰も見ていない状態から現れたときだけ問い直す）。
  func testAnotherWatcherDoesNotLookUpAgain() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .unavailable(.notGitHub)
    let pullRequest = watch()
    pumpMain(until: { pullRequest.answer == .unavailable(.notGitHub) })

    pullRequest.beginWatching()
    addTeardownBlock { @MainActor in pullRequest.endWatching() }
    XCTAssertTrue(holds(for: 1) { self.lookups == ["feat"] })
  }

  /// 問い合わせの最中に見ている者がいなくなったら、答えが届いても PR の状態を見始めない（見ていない PR を GitHub に
  /// 問い合わせ続けない）。
  func testAnAnswerArrivingAfterTheLastWatcherLeftDoesNotWatchThePullRequest() throws {
    holdsLookups = true
    let pullRequest = try watchAnOpenPullRequest()
    pumpMain(until: { self.held.count == 1 }, "前提: 問い合わせの最中")
    // PR の状態の鍵を作る `repo.open()` はランループを回すので、留めた問い合わせに答える前に作る。
    let key = PullRequestState.Key(
      commonDir: try repo.open().commonDir,
      id: try XCTUnwrap(GitHubItemID(repo: "me/r", number: 9)))
    pullRequest.endWatching()
    holdsLookups = false
    releaseLookups()

    let state = PullRequestState.shared(for: key, source: source)
    XCTAssertFalse(state.isWatched)
    XCTAssertNil(pullRequest.state, "答えは出さない")
  }

  /// 問い合わせの最中も見ている者が居れば、答えが届いたその場で PR の状態を見始める（去った後に届いた答えとの対）。
  func testAnAnswerArrivingWhileWatchedWatchesThePullRequestAtOnce() throws {
    holdsLookups = true
    let pullRequest = try watchAnOpenPullRequest()
    pumpMain(until: { self.held.count == 1 }, "前提: 問い合わせの最中")
    // PR の状態の鍵を作る `repo.open()` はランループを回すので、留めた問い合わせに答える前に作る（答えた後に回すと、PR の
    // 状態を見始めるのを待ってから確かめることになる）。
    let key = PullRequestState.Key(
      commonDir: try repo.open().commonDir,
      id: try XCTUnwrap(GitHubItemID(repo: "me/r", number: 9)))
    holdsLookups = false
    releaseLookups()

    let state = PullRequestState.shared(for: key, source: source)
    XCTAssertTrue(
      state.isWatched,
      "答えた直後に PR の状態を見始める。これが待たずに成り立たなくなったら、"
        + "testAnAnswerArrivingAfterTheLastWatcherLeftDoesNotWatchThePullRequest の確かめる時点も成り立たない")
    XCTAssertTrue(pullRequest.state === state, "答えを出す")
  }

  /// PR があれば、PR のベースブランチの追跡 ref が動いたときも問い直す。無関係なブランチの追跡 ref では問い直さない
  /// （PR の中身が届いてベースブランチが分かった後も）。
  func testAMoveOfThePullRequestsBaseTrackingRefLooksUpAgain() throws {
    let refs = try trackedBranch()
    repositories = ["origin": .github(me)]
    content = pullRequestContent(base: refs.main)
    answers["feat"] = .gitHub(
      GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([pr(9, state: "OPEN")]))
    let pullRequest = watch()
    pumpMain(until: { pullRequest.drift == .inSync }, "前提: PR の中身が届く")
    pumpMain(
      until: { !pullRequest.tracking.lacks("refs/remotes/origin/main") },
      "前提: ベースブランチの追跡 ref の値を覚える")
    let looked = lookups.count

    try moveRemoteRef("refs/remotes/origin/other", to: refs.main, watchedBy: refs.recorder)
    XCTAssertTrue(
      holds(for: 1) { self.lookups.count == looked }, "無関係なブランチの追跡 ref では問い直さない")

    let advanced = repo.git(["commit-tree", "main^{tree}", "-p", "main", "-m", "base"]).stdoutText
      .trimmingCharacters(in: .newlines)
    try moveRemoteRef("refs/remotes/origin/main", to: advanced, watchedBy: refs.recorder)
    pumpMain(until: { self.lookups.count == looked + 1 }, "ベースブランチの追跡 ref が動いたら問い直す")
  }

  /// PR が無くなって見る追跡 ref からベースブランチのものが外れた直後でも、push 先の追跡 ref の動きで問い直す。
  func testAPushRefMoveRightAfterThePullRequestIsGoneLooksUpAgain() throws {
    let refs = try trackedBranch()
    repositories = ["origin": .github(me)]
    content = pullRequestContent(base: refs.main)
    answers["feat"] = .gitHub(
      GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([pr(9, state: "OPEN")]))
    let pullRequest = watch()
    pumpMain(until: { pullRequest.drift == .inSync }, "前提: PR の中身が届く")
    pumpMain(
      until: { !pullRequest.tracking.lacks("refs/remotes/origin/main") },
      "前提: ベースブランチの追跡 ref の値を覚える")
    answers["feat"] = .gitHub(GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([]))
    pullRequest.reload()
    pumpMain(until: { pullRequest.state == nil && pullRequest.answer != .reading }, "前提: PR が無くなる")
    let looked = lookups.count

    try moveRemoteRef("refs/remotes/origin/feat", to: refs.main, watchedBy: refs.recorder)
    pumpMain(until: { self.lookups.count == looked + 1 }, "push 先の追跡 ref が動いたら問い直す")
  }

  /// 同じきっかけでは、worktree の今の PR と PR の diff タブが同じ PR を見ていても、中身の問い合わせは 1 回。パネルを隠して
  /// PR の diff タブだけが見ていても、きっかけで中身を読み直す（ブランチの PR は問い直さない）。
  func testATriggerReadsTheContentOnceAndTheTabAloneKeepsFollowing() throws {
    let refs = try trackedBranch()
    repositories = ["origin": .github(me)]
    content = pullRequestContent(base: refs.main)
    answers["feat"] = .gitHub(
      GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([pr(9, state: "OPEN")]))
    let pullRequest = watch()
    pumpMain(until: { pullRequest.state?.content != nil }, "前提: PR の中身が届く")
    let state = try XCTUnwrap(pullRequest.state)
    state.beginWatching()
    addTeardownBlock { @MainActor in state.endWatching() }
    contentReads = 0
    let notified = refs.recorder.moves

    SourceControl.shared(for: repo.root).fetch()
    pumpMain(until: { self.lookups.count == 2 }, timeout: 20, "前提: フェッチの後に問い直す")
    pumpMain(until: { !state.isReading }, "中身の読みが終わる")
    // フェッチは、リモート追跡の ref が動いたという知らせも出す。その知らせに続く追跡 ref の確かめが、いつ終わるかは外から
    // 見えない。
    pumpMain(until: { refs.recorder.moves > notified }, "前提: リモート追跡の ref が動いたと知らせる")
    XCTAssertTrue(holds(for: 1) { self.contentReads == 1 }, "中身の問い合わせは 1 回")

    pullRequest.endWatching()
    contentReads = 0
    try moveRemoteRef("refs/remotes/origin/feat", to: refs.main, watchedBy: refs.recorder)
    pumpMain(until: { self.contentReads == 1 }, "PR の diff タブだけで読み直す")
    XCTAssertEqual(lookups.count, 2, "ブランチの PR は問い直さない")
  }

  /// 去った後、根のサービスをほかに誰も持っていない状態で戻っても、1 回問い直す（根のサービスを作り直して status を待つ間も、
  /// 同じブランチ名だからと読み直しを捨てない）。
  func testComingBackWithNobodyHoldingTheRootLooksUpAgain() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .unavailable(.notGitHub)
    let pullRequest = watch()
    pumpMain(until: { pullRequest.answer == .unavailable(.notGitHub) })
    weak let root = RootFiles.shared(for: repo.root)
    pullRequest.endWatching()
    pumpMain(until: { root == nil }, "前提: 根のサービスをほかに誰も持っていない")

    pullRequest.beginWatching()
    pumpMain(until: { self.lookups.count == 2 }, "戻ったら問い直す")
    XCTAssertTrue(holds(for: 1) { self.lookups.count == 2 }, "1 回だけ")
  }

  /// 根のサービスがまだ無いまま、どのブランチにも居ない worktree を初めて見始めると、「ブランチに居ない」が出る（読んで
  /// いるのまま止まらない）。
  func testWatchingADetachedHeadForTheFirstTimeSaysSo() {
    XCTAssertTrue(repo.git(["switch", "-q", "--detach"]).isSuccess)
    let pullRequest = watch()
    pumpMain(until: { pullRequest.answer == .unavailable(.detached) }, "ブランチに居ない")
  }

  /// 問い合わせの最中に去り、答えが去った後に届き、根のサービスがほかに誰にも持たれず解けた後に戻っても、答えが出る（読んで
  /// いるのまま止まらない）。
  func testLeavingDuringAQueryAndComingBackWithNobodyHoldingTheRootAnswers() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .unavailable(.notGitHub)
    holdsLookups = true
    let pullRequest = watch()
    weak let root = RootFiles.shared(for: repo.root)
    pumpMain(until: { self.held.count == 1 }, "前提: 問い合わせの最中")
    pullRequest.endWatching()
    pumpMain(until: { root == nil }, "前提: 根のサービスをほかに誰も持っていない")
    holdsLookups = false
    releaseLookups()
    XCTAssertEqual(pullRequest.answer, .reading, "前提: 去った後に届いた答えは出さない")

    pullRequest.beginWatching()
    pumpMain(until: { pullRequest.answer == .unavailable(.notGitHub) }, "答えが出る")
  }

  /// 見始めてすぐ、GitHub に問い合わせを出す前に去れば、GitHub に問い合わせない。
  func testLeavingBeforeTheQueryIsSentAsksGitHubNothing() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .unavailable(.notGitHub)
    let pullRequest = watch()
    pumpMain(until: { pullRequest.answer == .unavailable(.notGitHub) })
    let root = RootFiles.shared(for: repo.root)
    pullRequest.endWatching()

    pullRequest.beginWatching()
    pullRequest.endWatching()
    XCTAssertTrue(holds(for: 1) { self.lookups == ["feat"] })
    XCTAssertTrue(root.isResolved, "前提: 根のサービスは判定済みのまま（問い合わせに進める状態）")
    pullRequest.beginWatching()
    pumpMain(until: { self.lookups.count == 2 }, "戻ったら問い直す")
  }

  /// PR が無いブランチで、ブランチの PR の答えが届く前に見ている者が去れば、ブランチが GitHub に在るかを問い合わせない。
  func testLeavingBeforeTheAnswerSkipsThePublishedCheck() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .gitHub(GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([]))
    holdsLookups = true
    let pullRequest = watch()
    pumpMain(until: { self.held.count == 1 }, "前提: 問い合わせの最中")
    pullRequest.endWatching()
    releaseLookups()
    XCTAssertEqual(publishedChecks, [])
  }

  /// PR が無いブランチで、問い合わせの最中も見ている者が居れば、答えが届いたその場で、ブランチが GitHub に在るかを問い合わせる
  /// （答えの前に去った場合との対）。
  func testAnAnswerWhileWatchedAsksWhetherTheBranchIsPublishedAtOnce() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .gitHub(GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([]))
    holdsLookups = true
    _ = watch()
    pumpMain(until: { self.held.count == 1 }, "前提: 問い合わせの最中")
    releaseLookups()
    XCTAssertEqual(
      publishedChecks, [GitHubBranchRef(repo: me, branch: "feat")],
      "答えた直後に在るかを問い合わせる。これが待たずに成り立たなくなったら、"
        + "testLeavingBeforeTheAnswerSkipsThePublishedCheck の確かめる時点も成り立たない")
  }

  /// PR が無いブランチで、前の答えの「GitHub に在るか」を確かめている最中に読み直し、その答えが届いて先行の数を数え終わる
  /// 前に見ている者が去れば、去った後に「GitHub に在るか」を問い合わせない。
  func testLeavingWhileAReloadCountsSkipsThePublishedCheckEvenWithAnEarlierAnswer() {
    // 既定のブランチの追跡 ref があると、先行の数を git で数える（答えを出すのは数え終わった後）。
    repo.addOrigin()
    XCTAssertTrue(repo.git(["remote", "set-head", "origin", "main"]).isSuccess)
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .gitHub(GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([]))
    holdsPublishedChecks = true
    let pullRequest = watch()
    pumpMain(until: { self.publishedChecks.count == 1 }, "前提: 前の答えの在るかを確かめている")
    holdsLookups = true
    pullRequest.reload()
    pumpMain(until: { self.held.count == 1 }, "前提: 読み直しの問い合わせの最中")

    releaseLookups()
    pullRequest.endWatching()
    XCTAssertTrue(holds(for: 1) { self.publishedChecks.count == 1 }, "去った後に問い合わせない")
  }

  /// 読み直しで前と同じ値の答えが出たら、前の答えの「GitHub に在るか」の結果は入れず、今の答えの結果だけを入れる。
  func testAnEarlierPublishedCheckDoesNotLandOnTheNextAnswer() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .gitHub(GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([]))
    holdsPublishedChecks = true
    let pullRequest = watch()
    pumpMain(until: { self.heldChecks.count == 1 }, "前提: 前の答えの在るかを確かめている")
    pullRequest.reload()
    pumpMain(until: { self.heldChecks.count == 2 }, "前提: 同じ値の今の答えの在るかを確かめている")

    heldChecks[0](.success(false))
    XCTAssertEqual(published(pullRequest), .checking, "前の答えの結果は入れない")
    heldChecks[1](.success(true))
    XCTAssertEqual(published(pullRequest), .yes)
  }

  // MARK: - ヘルパ

  /// 作成の入口の材料の、ブランチが GitHub に在るか（PR が無い答えでなければ nil）。
  private func published(_ pullRequest: BranchPullRequest) -> BranchPullRequest.Published? {
    guard case .noPullRequest(let creation) = pullRequest.answer else { return nil }
    return creation.published
  }

  /// 留めた問い合わせに答える。
  func releaseLookups() {
    let answers = held
    held = []
    for answer in answers { answer() }
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
}

/// 根のサービスの、リモート追跡の ref が動いたという知らせを数える。
@MainActor
final class RemoteRefsRecorder: RootFilesObserver {
  var moves = 0
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {}
  func rootFilesStatusDidChange(_ files: RootFiles) {}
  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {}
  func rootFilesGitStateDidChange(_ files: RootFiles, remoteRefsChanged: Bool) {
    if remoteRefsChanged { moves += 1 }
  }
}
