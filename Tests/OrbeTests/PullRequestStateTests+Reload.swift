import XCTest

@testable import Orbe

/// PR ごとの状態が自分のきっかけで中身を読み直すこと——PR の先頭のブランチとベースブランチの追跡 ref の動きと、Orbe の
/// 中のネット操作の終わり。見ている者がいる間だけ読む。
///
/// 壊れると何が起きるか: 端末での push や fetch の後も PR のパネルと PR の diff タブが古い中身のまま。無関係なブランチの
/// fetch のたびに GitHub へ問い合わせる。パネルもタブも閉じた PR を問い合わせ続ける。
extension PullRequestStateTests {
  /// PR の先頭のブランチかベースブランチの追跡 ref が動けば読み直し、無関係なブランチの追跡 ref では読み直さない。
  func testOnlyAMoveOfThePullRequestsTrackingRefsReadsAgain() throws {
    let tracked = try trackedState()

    tracked.move("refs/remotes/origin/other", to: tracked.main)
    letGitSettle()
    XCTAssertTrue(gitHub.contentRequests.isEmpty, "無関係なブランチの追跡 ref では読み直さない")

    tracked.move("refs/remotes/origin/feat", to: tracked.main)
    pumpMain(until: { self.gitHub.contentRequests.count == 1 }, "先頭のブランチの追跡 ref で読み直す")
    gitHub.answerContent()

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
    letGitSettle()
    XCTAssertTrue(gitHub.contentRequests.isEmpty, "見ている者がいなければ読まない")
  }

  /// 読み直しが追跡 ref の値を読んでいる間に最後の見ている者が去れば、GitHub に問い合わせない。
  func testLeavingWhileTheTrackingRefsAreReadAsksGitHubNothing() throws {
    let tracked = try trackedState()

    tracked.state.reload()
    tracked.state.endWatching()
    letGitSettle()
    XCTAssertTrue(gitHub.contentRequests.isEmpty, "見ている者がいなければ問い合わせない")
  }

  // MARK: - 道具

  /// origin に送ったブランチ feat（main より 1 コミット先）の PR の状態。見ている者が 1 人いて、中身を 1 回読み、追跡 ref の
  /// 値を覚えたところ。以後の中身の問い合わせは答えずに留める。
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
    state.reload()
    pumpMain(
      until: { self.gitHub.contentRequests.count == 1 }, "前提: 追跡 ref の値を覚えてから問い合わせる")
    gitHub.answerContent()
    return TrackedState(repo: repo, state: state, main: main, head: head, recorder: recorder)
  }

  /// 問い合わせと、その前後の git の読み取りが、起きるなら終わるまで main を回す（起きなかったことは外から見えない）。
  private func letGitSettle() {
    let until = Date().addingTimeInterval(1)
    while Date() < until {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
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
    let until = Date().addingTimeInterval(10)
    while recorder.moves == before, Date() < until {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    XCTAssertGreaterThan(recorder.moves, before, "前提: リモート追跡の ref が動いたと知らせる")
  }
}
