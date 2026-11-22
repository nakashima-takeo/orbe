import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR ごとの状態が自分のきっかけで中身を読み直すこと——PR の先頭のブランチとベースブランチの追跡 ref の動きと、Orbe の
/// 中のネット操作の終わり。見ている者がいる間だけ読む。
///
/// 壊れると何が起きるか: 端末での push や fetch の後も PR のパネルと PR の diff タブが古い中身のまま。無関係なブランチの
/// fetch のたびに GitHub へ問い合わせる。パネルもタブも閉じた PR を問い合わせ続ける。
extension PullRequestStateTests {
  /// PR の先頭のブランチかベースブランチの追跡 ref が動けば読み直し、無関係なブランチの追跡 ref では読み直さない。最初の
  /// 中身が届いた時点で追跡 ref の値を覚えるので、開いた後の最初の動きにも追従する。
  func testOnlyAMoveOfThePullRequestsTrackingRefsReadsAgain() throws {
    let tracked = try trackedState()

    tracked.move("refs/remotes/origin/feat", to: tracked.main)
    pumpMain(until: { self.gitHub.contentRequests.count == 1 }, "先頭のブランチの追跡 ref で読み直す")
    gitHub.answerContent()

    tracked.move("refs/remotes/origin/other", to: tracked.main)
    XCTAssertTrue(
      holds(for: 1) { self.gitHub.contentRequests.isEmpty }, "無関係なブランチの追跡 ref では読み直さない")

    tracked.move("refs/remotes/origin/main", to: tracked.head)
    pumpMain(until: { self.gitHub.contentRequests.count == 1 }, "ベースブランチの追跡 ref で読み直す")
  }

  /// Orbe の中のネット操作が終われば読み直す。最後の見ている者が去った後は、追跡 ref が動いても読まない。
  func testANetworkOperationReadsAgainAndNothingIsReadAfterTheWatchersLeave() throws {
    let tracked = try trackedState()

    SourceControl.shared(for: tracked.repo.root).fetch()
    pumpMain(
      until: { self.gitHub.contentRequests.count == 1 }, timeout: 20, "フェッチの後に読み直す")
    gitHub.answerContent()

    tracked.state.endWatching()
    tracked.move("refs/remotes/origin/feat", to: tracked.main)
    XCTAssertTrue(holds(for: 1) { self.gitHub.contentRequests.isEmpty }, "見ている者がいなければ読まない")
  }

  /// 読み直しが追跡 ref の値を読んでいる間に最後の見ている者が去れば、GitHub に問い合わせず、戻ったら読み直す。
  func testLeavingWhileTheTrackingRefsAreReadAsksGitHubNothing() throws {
    let tracked = try trackedState()

    tracked.state.reload()
    tracked.state.endWatching()
    pumpMain(until: { self.readEndedOrAsked(tracked.state) }, "追跡 ref の値を読み終える")
    XCTAssertTrue(gitHub.contentRequests.isEmpty, "見ている者がいなければ問い合わせない")

    tracked.state.beginWatching()
    pumpMain(until: { self.readEndedOrAsked(tracked.state) }, "追跡 ref の値を読み終える")
    XCTAssertEqual(gitHub.contentRequests.count, 1, "戻ったら読み直す")
  }

  // MARK: - 道具

  /// origin に送ったブランチ feat（main より 1 コミット先）の PR の状態。見ている者が 1 人いて、最初の中身を読み、その
  /// 中身から分かった追跡 ref の値を覚えたところ。以後の中身の問い合わせは答えずに留める。
  private func trackedState() throws -> TrackedState {
    let repo = try TempGitRepo()
    repo.addOrigin()
    let main = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "pr"]).isSuccess)
    let head = repo.head()
    XCTAssertTrue(repo.git(["push", "-q", "-u", "origin", "feat"]).isSuccess)
    let recorder = RemoteRefsRecorder()
    let files = RootFiles.shared(for: repo.root)
    files.addObserver(recorder)
    addTeardownBlock { @MainActor in files.removeObserver(recorder) }

    gitHub.content = .success(content(base: main, head: head))
    let state = PullRequestState.shared(for: key, source: gitHub.source)
    state.attach(repo: try repo.open(), fetchRemote: "origin", headRemote: "origin")
    state.beginWatching()
    addTeardownBlock { @MainActor in state.endWatching() }
    pumpMain(until: { state.content != nil }, "前提: 中身が読める")
    gitHub.answersAtOnce = false
    pumpMain(
      until: { !state.trackedRefs.contains(where: state.tracking.lacks) },
      "前提: 中身から分かった追跡 ref の値を覚える")
    return TrackedState(repo: repo, state: state, main: main, head: head, recorder: recorder)
  }

  /// 読み直しが、問い合わせを出さずに終わったか、問い合わせを出した（留めた問い合わせの答えを待つ間も、読んでいる最中）。
  private func readEndedOrAsked(_ state: PullRequestState) -> Bool {
    !state.isReading || !gitHub.contentRequests.isEmpty
  }
}

/// 追跡するブランチを持つ一時リポジトリと、それに結んだ PR の状態。
@MainActor
private struct TrackedState {
  let repo: TempGitRepo
  let state: PullRequestState
  let main: String
  let head: String
  let recorder: RemoteRefsRecorder

  /// リモート追跡の ref `ref` を `commit` に動かし、根のサービスがそれを知らせるまで待つ。
  func move(_ ref: String, to commit: String) {
    let before = recorder.moves
    XCTAssertTrue(repo.git(["update-ref", ref, commit]).isSuccess)
    waitUntil(10) { recorder.moves != before }
    XCTAssertGreaterThan(recorder.moves, before, "前提: リモート追跡の ref が動いたと知らせる")
  }
}
