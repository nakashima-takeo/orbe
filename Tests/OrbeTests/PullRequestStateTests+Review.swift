import XCTest

@testable import Orbe

/// PR ごとの状態が持つレビューのやりとり——読むきっかけ、先頭のコミットが古いときのスレッド、書き込みを受け付けない場合。
/// 書き込みの順番・結果の返し方・書き込みの後の読み直しは `PullRequestStateTests+ReviewOrder` が守る。GitHub は差し替えの
/// 構造体が答える。
///
/// 壊れると何が起きるか: 誰も見ていない PR を問い合わせる。push の後に、古い版の行のスレッドを新しい版の行に置く・古い版の
/// 行番号で新しいスレッドを書く。
extension PullRequestStateTests {
  private func review(head: String = "h", threads: [String] = []) -> GitHubPullRequestReview {
    GitHubPullRequestReview(
      viewer: "me", viewerIsAuthor: false, headCommit: head, pendingReview: nil,
      threads: threads.map {
        .init(
          id: $0, path: "a", side: .new, line: 1, isResolved: false, canReply: true,
          canResolve: true, canUnresolve: false, comments: [])
      })
  }

  /// 中身とレビューのやりとりを読み終え、見ている者がいる状態。
  private func readState() -> PullRequestState {
    let state = PullRequestState.shared(for: key, source: gitHub.source)
    state.beginWatching()
    addTeardownBlock { @MainActor in state.endWatching() }
    gitHub.content = .success(content())
    gitHub.review = .success(review())
    state.reload()
    return state
  }

  // MARK: - 読み

  /// 中身と同じきっかけでレビューのやりとりを読む。読んでいる間の読み直しは、終わった後に 1 回だけ行う。誰も見ていなければ読まない。
  func testTheReviewIsReadWithTheContentAndOnlyWhileWatched() {
    let state = PullRequestState.shared(for: key, source: gitHub.source)
    gitHub.content = .success(content())
    state.reload()
    XCTAssertEqual(gitHub.reviewReads, 0, "見ている者がいなければ読まない")

    gitHub.answersReviewAtOnce = false
    state.beginWatching()
    addTeardownBlock { @MainActor in state.endWatching() }
    state.reload()
    state.reload()
    XCTAssertEqual(gitHub.reviewReads, 1)
    gitHub.answerReview()
    XCTAssertEqual(gitHub.reviewReads, 2, "終わった後の 1 回")
    gitHub.answerReview()
    XCTAssertEqual(gitHub.reviewReads, 2, "それより多くは読まない")
    XCTAssertEqual(state.review, review())
  }

  /// スレッドは、読んだ時点の PR の先頭のコミットを先頭とする diff にだけ置ける。
  func testThreadsReadAtAnotherHeadAreNotPlaced() {
    let state = readState()
    gitHub.review = .success(review(head: "h", threads: ["T1"]))
    state.reload()
    XCTAssertEqual(state.threads(at: "h")?.map(\.id), ["T1"])
    XCTAssertNil(state.threads(at: "h2"), "diff が見せている先頭と違う間は、スレッドはまだ無い")
  }

  // MARK: - 書き込み

  /// 中身とレビューのやりとりが読めるまでは、書き込みを受け付けない。
  func testWritesAreRefusedUntilTheReviewIsRead() {
    let state = PullRequestState.shared(for: key, source: gitHub.source)
    gitHub.content = .success(content())
    gitHub.review = .failure(.unreachable)
    state.beginWatching()
    addTeardownBlock { @MainActor in state.endWatching() }
    XCTAssertNotNil(state.content)
    XCTAssertFalse(state.write(.submit(.comment, body: "x")) { _ in })
    XCTAssertTrue(gitHub.reviewWrites.isEmpty)
  }

  /// 新しいスレッドは、行を数えた先頭のコミットが、レビューのやりとりを読んだ時点の先頭のコミットと同じときだけ受け付ける
  /// （push の後、読み直しが届くまでは、古い版の行番号で書かせない）。
  func testANewThreadOnAnotherHeadIsRefused() {
    let state = readState()
    XCTAssertFalse(
      state.write(.addThread(path: "a", side: .new, line: 1, commit: "h2", body: "x")) { _ in })
    XCTAssertTrue(gitHub.reviewWrites.isEmpty)
    XCTAssertTrue(
      state.write(.addThread(path: "a", side: .new, line: 1, commit: "h", body: "x")) { _ in })
  }
}
