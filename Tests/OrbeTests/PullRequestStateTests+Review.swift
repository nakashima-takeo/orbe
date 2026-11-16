import XCTest

@testable import Orbe

/// PR ごとの状態が持つレビューのやりとり——読み、書き込みの順番・受け付け・結果の返し方、書き込みの後の読み直し、先頭の
/// コミットが古いときのスレッド。GitHub は差し替えの構造体が答える。
///
/// 壊れると何が起きるか: 2 回押した返信やレビューの送信が 2 回送られる。書き込みの結果が頼んだ呼び出し元に返らない・2 回返る。書き込みの
/// 前に出した読みの答えで、書いたコメントが消えて見える。タイムアウトした書き込みが実は通っていたことが分からない。誰も見ていない PR を
/// 問い合わせる。push の後に、古い版の行のスレッドを新しい版の行に置く。
extension PullRequestStateTests {
  private func review(head: String = "h", pending: String? = nil, threads: [String] = [])
    -> GitHubPullRequestReview
  {
    GitHubPullRequestReview(
      viewer: "me", viewerIsAuthor: false, headCommit: head,
      pendingReview: pending.map { .init(id: $0, commentCount: 1) },
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

  private final class Results {
    var values: [GitHubFailure?] = []
  }

  private func write(_ state: PullRequestState, _ write: GitHubReviewWrite, into results: Results)
    -> Bool
  {
    state.write(write) { results.values.append($0) }
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

  /// スレッドは、読んだ時点の PR の先頭のコミットと先頭が同じ diff にだけ置ける。
  func testThreadsReadAtAnotherHeadAreNotPlaced() {
    let state = readState()
    gitHub.review = .success(review(head: "h", threads: ["T1"]))
    state.reload()
    XCTAssertEqual(state.threads(at: "h")?.map(\.id), ["T1"])
    XCTAssertNil(state.threads(at: "h2"), "diff が見せている先頭と違う間は、スレッドはまだ無い")
  }

  // MARK: - 書き込み

  /// 書き込みは 1 つずつ順に送り、答えの後の読み直しが届いてから、頼んだ者へ 1 回だけ結果を返す。
  func testWritesGoOneAtATimeAndAnswerOnceAfterTheReread() {
    let state = readState()
    let first = Results()
    let second = Results()
    XCTAssertTrue(write(state, .addThread(path: "a", side: .new, line: 1, body: "x"), into: first))
    XCTAssertTrue(write(state, .addThread(path: "a", side: .new, line: 2, body: "y"), into: second))
    XCTAssertEqual(gitHub.reviewWrites.count, 1, "前の書き込みが終わってから次を送る")

    gitHub.answersReviewAtOnce = false
    let reads = gitHub.reviewReads
    gitHub.finishReviewWrite()
    XCTAssertEqual(gitHub.reviewReads, reads + 1, "答えの後に読み直す")
    XCTAssertTrue(first.values.isEmpty, "読み直しが届くまで終わらない")
    gitHub.review = .success(review(threads: ["T1"]))
    gitHub.answerReview()
    XCTAssertEqual(first.values.count, 1)
    XCTAssertNil(first.values[0] ?? nil)
    XCTAssertEqual(state.review?.threads.map(\.id), ["T1"])
    XCTAssertEqual(gitHub.reviewWrites.count, 1, "次の書き込みを送る")
    XCTAssertTrue(second.values.isEmpty)
  }

  /// 同じスレッドへの書き込みと、レビューの送信は、走っている間に次を受け付けない。終われば受け付ける。
  func testAThreadOrASubmissionBeingWrittenRefusesTheNextWrite() {
    let state = readState()
    let results = Results()
    XCTAssertTrue(write(state, .reply(thread: "T1", body: "x", resolve: false), into: results))
    XCTAssertFalse(write(state, .setResolved(thread: "T1", true), into: results))
    XCTAssertTrue(write(state, .setResolved(thread: "T2", true), into: results), "別のスレッドは受ける")
    XCTAssertTrue(write(state, .submit(.approve, body: ""), into: results))
    XCTAssertFalse(write(state, .submit(.approve, body: ""), into: results), "送信を 2 回送らない")
    XCTAssertTrue(state.isWriting(.thread("T1")) && state.isWriting(.submission))

    gitHub.finishReviewWrite()
    XCTAssertFalse(state.isWriting(.thread("T1")))
    XCTAssertTrue(write(state, .setResolved(thread: "T1", true), into: results))
    gitHub.finishReviewWrite()
    gitHub.finishReviewWrite()
    XCTAssertFalse(state.isWriting(.submission))
    XCTAssertEqual(results.values.count, 3)
  }

  /// 書き込みの答えより前に出した読みの答えは反映しない（書き込みが反映される前の状態でありうる）。その後に出した読みの答えは反映する。
  func testAReadIssuedBeforeTheWriteAnswerDoesNotOverwriteTheReread() {
    let state = readState()
    gitHub.answersReviewAtOnce = false
    let results = Results()
    XCTAssertTrue(write(state, .reply(thread: "T1", body: "x", resolve: false), into: results))
    state.reload()
    gitHub.finishReviewWrite()
    gitHub.review = .success(review(threads: ["before"]))
    gitHub.answerReview()
    XCTAssertEqual(state.review, review(), "書き込みの答えより前に出した読みは入れない")
    XCTAssertTrue(results.values.isEmpty, "その読みでは終わらない")

    gitHub.review = .success(review(threads: ["after"]))
    gitHub.answerReview()
    XCTAssertEqual(state.review?.threads.map(\.id), ["after"])
    XCTAssertEqual(results.values.count, 1)
  }

  /// タイムアウトした書き込みの後も読み直し、書き込みは失敗として返る（GitHub に届いていれば、読み直しの答えに出る）。書き込みが
  /// 通って読み直しが失敗したら、書き込みは成功として返り、状態は読みの失敗を持つ。
  func testATimedOutWriteIsReadAgainAndAFailedRereadKeepsTheWriteSuccessful() {
    let state = readState()
    let results = Results()
    XCTAssertTrue(write(state, .reply(thread: "T1", body: "x", resolve: false), into: results))
    gitHub.review = .success(review(pending: "R1", threads: ["T1"]))
    gitHub.finishReviewWrite(failure: .timedOut)
    XCTAssertEqual(results.values.count, 1)
    XCTAssertEqual(results.values[0], .timedOut)
    XCTAssertEqual(state.review?.pendingReview?.id, "R1", "届いていた書き込みが出る")

    XCTAssertTrue(write(state, .reply(thread: "T1", body: "y", resolve: false), into: results))
    XCTAssertEqual(gitHub.reviewWrites.first?.pendingReview, "R1", "書き込みは、読み直しで分かった保留中のレビューを指定する")
    gitHub.review = .failure(.unreachable)
    gitHub.finishReviewWrite()
    XCTAssertEqual(results.values.count, 2)
    XCTAssertNil(results.values[1] ?? nil)
    XCTAssertEqual(state.failure, .read(.unreachable))
  }

  /// 見ている者が去っても、受け付けた書き込みは順に最後まで送られ、結果を返す。読み直しはしない（誰も見ていない間は
  /// 問い合わせない）。次の書き込みは、前の書き込みの答えで分かった保留中のレビューを指定する。見ている者が戻れば読み直す。
  func testWritesKeepGoingWithoutRereadsAfterTheWatchersLeave() {
    let state = readState()
    let results = Results()
    XCTAssertTrue(
      write(state, .addThread(path: "a", side: .new, line: 1, body: "x"), into: results))
    XCTAssertTrue(write(state, .reply(thread: "T1", body: "y", resolve: false), into: results))
    state.endWatching()
    let reads = gitHub.reviewReads
    gitHub.finishReviewWrite(pendingReview: "R9")
    XCTAssertEqual(results.values.count, 1)
    XCTAssertEqual(gitHub.reviewReads, reads, "読み直さない")
    XCTAssertEqual(gitHub.reviewWrites.first?.pendingReview, "R9")
    gitHub.finishReviewWrite()
    XCTAssertEqual(results.values.count, 2)
    XCTAssertEqual(gitHub.reviewReads, reads)

    state.beginWatching()
    XCTAssertEqual(gitHub.reviewReads, reads + 1, "戻れば読み直す")
  }

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
}
