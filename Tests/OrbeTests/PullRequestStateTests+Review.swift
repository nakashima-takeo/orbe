import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR ごとの状態が持つレビューのやりとり——読むきっかけ、先頭のコミットが古いときのスレッド、中身との先頭の食い違いで読み直す
/// こと、書き込みを受け付けない場合。書き込みの順番・結果の返し方・書き込みの後の読み直しは `PullRequestStateTests+ReviewOrder`
/// が守る。GitHub は差し替えの構造体が答える。
///
/// 壊れると何が起きるか: 誰も見ていない PR を問い合わせる。push の後に、古い版の行のスレッドを新しい版の行に置く・古い版の
/// 行番号で新しいスレッドを書く。書いている間に push があると、次のきっかけまでスレッドを置けず、新しいスレッドも書けない。
/// 2 回押した送信が 2 回送られる・承認が利用者の見ていないコミットに付く。
extension PullRequestStateTests {
  private func review(head: String = "h", threads: [String] = []) -> GitHubPullRequestReview {
    GitHubPullRequestReview(
      viewerIsAuthor: false, headCommit: head, pendingReview: nil,
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

  // MARK: - 先頭のコミットを揃える

  private var reads: Int { gitHub.contentReads + gitHub.reviewReads }

  /// 中身とレビューのやりとりを並べて読む間に push があり、中身が push の後を、レビューのやりとりが push の前を答えても（届く
  /// 順が出した順と逆でも）、続く 2 本の読み直しで揃う。読みは、push 1 回の読み直しで 4 本まで。
  func testHeadsReadAcrossAPushAreAlignedByRereadingBoth() {
    let state = readState()
    gitHub.answersAtOnce = false
    gitHub.answersReviewAtOnce = false
    let before = reads
    state.reload()
    gitHub.content = .success(content(head: "h1"))
    gitHub.answerContent()
    gitHub.answerReview()
    gitHub.review = nil

    gitHub.answerReview()
    gitHub.answerContent()

    XCTAssertEqual(reads, before + 4)
    XCTAssertNotNil(state.threads(at: "h1"))
    XCTAssertTrue(
      state.writeReview(.addThread(path: "a", side: .new, line: 1, commit: "h1", body: "x")) { _ in
      })
  }

  /// 書き込みの後の読み直しが中身より新しい先頭を読んだら（書いている間の push）、次のきっかけを待たずに両方を読み直して
  /// 揃える。読みは、書き込みの後の 1 本と揃える 2 本。
  func testAReviewReadAheadOfTheContentAfterAWriteIsAligned() {
    let state = readState()
    XCTAssertTrue(state.writeReview(.setResolved(thread: "T1", true)) { _ in })
    gitHub.review = .success(review(head: "h2", threads: ["T1"]))
    gitHub.content = .success(content(head: "h2"))
    let before = reads

    gitHub.finishReviewWrite()

    XCTAssertEqual(reads, before + 3)
    XCTAssertEqual(state.threads(at: "h2")?.map(\.id), ["T1"])
  }

  /// 揃える 2 本が前と同じ 2 つの先頭で食い違って返ったら（GitHub の答えが一貫していない）、問い合わせを往復させない。次の
  /// きっかけで、また揃えにいく。
  func testAMismatchThatSurvivesTheRereadWaitsForTheNextTrigger() {
    let state = readState()
    gitHub.review = .success(review(head: "h2"))
    XCTAssertTrue(state.writeReview(.setResolved(thread: "T1", true)) { _ in })
    let before = reads
    gitHub.finishReviewWrite()
    XCTAssertEqual(reads, before + 3, "揃える 2 本の後は読まない")
    XCTAssertEqual(state.content?.headCommit, "h", "前提: 中身の答えが遅れている")

    gitHub.content = .success(content(head: "h2"))
    state.reload()
    XCTAssertEqual(state.content?.headCommit, "h2")
  }

  /// 揃える読みが失敗したら、もう一方がまだ見ていない先頭を読んでいても、その失敗を持って揃えるのをやめる。次のきっかけで
  /// 揃い、中身が読めたら失敗は消える。
  func testAFailedAligningReadStopsWithTheFailureUntilTheNextTrigger() {
    let state = readState()
    gitHub.answersReviewAtOnce = false
    XCTAssertTrue(state.writeReview(.setResolved(thread: "T1", true)) { _ in })
    let before = reads
    gitHub.finishReviewWrite()
    gitHub.review = .success(review(head: "h2"))
    gitHub.content = .failure(.unreachable)
    gitHub.answerReview()
    gitHub.review = .success(review(head: "h3"))
    gitHub.answerReview()
    XCTAssertEqual(reads, before + 3, "揃える 2 本の後は読まない")
    XCTAssertEqual(state.contentFailure, .unreachable)

    gitHub.content = .success(content(head: "h3"))
    state.reload()
    gitHub.answerReview()
    XCTAssertEqual(state.content?.headCommit, "h3")
    XCTAssertEqual(state.review?.headCommit, "h3")
    XCTAssertNil(state.contentFailure)
  }

  /// 中身とレビューのやりとりの問い合わせにすぐ答えが返っても、push の後の読み直しで中身とレビューのやりとりが同じ先頭を
  /// 読めば、揃えるための読みは出ない（前に読んだレビューのやりとりの先頭と、届いた新しい中身の先頭とを、新しいレビューの
  /// やりとりの答えが届く前に見比べることはしない）。
  func testHeadsThatAgreeAfterAPushNeedNoMoreReads() {
    let state = readState()
    gitHub.content = .success(content(head: "h1"))
    gitHub.review = nil
    let before = reads

    state.reload()

    XCTAssertEqual(reads, before + 2)
    XCTAssertNotNil(state.threads(at: "h1"))
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
    XCTAssertFalse(state.writeReview(.reply(thread: "T1", body: "x", resolve: false)) { _ in })
    XCTAssertTrue(gitHub.reviewWrites.isEmpty)
  }

  /// 新しいスレッドは、行を数えた先頭のコミットが、レビューのやりとりを読んだ時点の先頭のコミットと同じときだけ受け付ける
  /// （push の後、読み直しが届くまでは、古い版の行番号で書かせない）。
  func testANewThreadOnAnotherHeadIsRefused() {
    let state = readState()
    XCTAssertFalse(
      state.writeReview(.addThread(path: "a", side: .new, line: 1, commit: "h2", body: "x")) { _ in
      })
    XCTAssertTrue(gitHub.reviewWrites.isEmpty)
    XCTAssertTrue(
      state.writeReview(.addThread(path: "a", side: .new, line: 1, commit: "h", body: "x")) { _ in }
    )
  }

  // MARK: - レビューの送信

  /// 本物の git の PR（ベースの上に 1 件）の状態を、diff の両端・中身・レビューのやりとりの先頭が揃うまで読む。
  private func submittableState() throws -> (TempGitRepo, PullRequestState) {
    let repo = try TempGitRepo()
    let base = repo.head()
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "pr"]).isSuccess)
    let state = PullRequestState.shared(for: key, source: gitHub.source)
    state.attach(repo: try repo.open(), fetchRemote: nil, headRemote: nil)
    gitHub.content = .success(content(base: base, head: repo.head()))
    state.beginWatching()
    addTeardownBlock { @MainActor in state.endWatching() }
    pumpMain(until: { state.isReviewAligned }, "前提: diff の両端・中身・レビューのやりとりの先頭が揃う")
    return (repo, state)
  }

  /// PR に push する——手元の PR にコミットを足し、GitHub の中身をその先頭にして読み直す。
  private func push(_ repo: TempGitRepo, _ state: PullRequestState) throws {
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "push"]).isSuccess)
    let previous = try XCTUnwrap(gitHub.content.get())
    gitHub.content = .success(content(base: previous.baseCommit, head: repo.head()))
    state.reload()
  }

  /// diff の両端が揃った PR の送信は受け付け、利用者が見ていた先頭のコミットに結ぶ。送信が走っている間の 2 回目は受け付けず、
  /// 終われば次の送信を受け付ける。
  func testASubmissionIsSentOnceAndBoundToTheSeenHead() throws {
    let (repo, state) = try submittableState()
    XCTAssertTrue(state.writeReview(.submit(.approve, body: "")) { _ in })
    XCTAssertFalse(state.writeReview(.submit(.approve, body: "")) { _ in }, "走っている間の 2 回目")
    XCTAssertEqual(gitHub.reviewWrites.map(\.write), [.submit(.approve, body: "")])
    XCTAssertEqual(gitHub.reviewWrites.first?.reviewedCommit, repo.head())

    gitHub.finishReviewWrite()
    pumpMain(until: { !state.isWritingReview(.submission) }, "送信が終わる")
    XCTAssertTrue(state.writeReview(.submit(.comment, body: "次")) { _ in }, "終われば次を受け付ける")
  }

  /// push の後、レビューのやりとりがまだ前の先頭のものなら、送信を受け付けない（承認を、diff で見ていないコミットに付けない）。
  func testASubmissionIsRefusedWhileTheReviewIsOfAnotherHead() throws {
    let (repo, state) = try submittableState()
    let seen = repo.head()
    gitHub.review = .success(review(head: seen))
    try push(repo, state)
    pumpMain(
      until: {
        state.content?.headCommit == repo.head() && !state.isReading && !state.isReadingReview
      },
      "中身だけが新しい先頭になる")

    XCTAssertFalse(state.writeReview(.submit(.approve, body: "")) { _ in })
    XCTAssertTrue(gitHub.reviewWrites.isEmpty)
  }

  /// 前の書き込みの後ろに積んだ送信は、送るまでに push があって先頭が進んでも、受け付けた時点に利用者が見ていた先頭に結ぶ。
  func testAQueuedSubmissionKeepsTheHeadSeenWhenItWasAccepted() throws {
    let (repo, state) = try submittableState()
    let seen = repo.head()
    XCTAssertTrue(state.writeReview(.reply(thread: "T", body: "x", resolve: false)) { _ in })
    XCTAssertTrue(state.writeReview(.submit(.approve, body: "")) { _ in })
    try push(repo, state)
    pumpMain(until: { state.isReviewAligned && state.review?.headCommit == repo.head() }, "先頭が進む")

    gitHub.finishReviewWrite()
    pumpMain(until: { gitHub.reviewWrites.count == 1 }, "積んだ送信を送る")
    XCTAssertEqual(gitHub.reviewWrites.first?.write, .submit(.approve, body: ""))
    XCTAssertEqual(gitHub.reviewWrites.first?.reviewedCommit, seen)
  }
}
