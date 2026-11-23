import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR のパネルの下端の区画とファイルの行のコメント数。壊れると何が起きるか: 空のコメントを送信できる・行に書いた保留中の
/// コメントを本文なしで送れない・自分の PR を承認できるように見える・失敗した送信で書きかけが消える・成功した後も書きかけと
/// 選んだ種類が残る・古い版の行のスレッドをコメント数に数える・今の diff に出せないスレッドに気づけない・空白だけの
/// レビューを公開できる・diff で見ていないコミットに承認が付く・解決済みの置けないスレッドが件数を埋める。
extension PrPanelTests {
  /// 「コメント」「変更を依頼」は本文も保留中のコメントも無ければ送れず、「承認」は空でも送れる。送信が成功すれば書きかけは空になり種類は
  /// 「コメント」に戻る。成功しなければ書きかけと種類が残り、失敗を保持する。
  func testSubmittingAReviewNeedsABodyUnlessApprovingAndKeepsTheDraftOnFailure() throws {
    let state = try reviewed()
    XCTAssertFalse(panel.canSubmitReview, "空のコメントは送れない")
    state.chooseReviewEvent(.requestChanges)
    XCTAssertFalse(panel.canSubmitReview, "空の変更の依頼は送れない")
    state.chooseReviewEvent(.approve)
    XCTAssertTrue(panel.canSubmitReview, "承認は空でも送れる")
    state.reviewDraft.body = "見ました"
    panel.submitReview()
    XCTAssertEqual(reviewWrites, [.submit(.approve, body: "見ました")])
    XCTAssertEqual(
      state.reviewDraft, PullRequestState.ReviewDraft(), "成功すれば書きかけを空にし、種類を「コメント」に戻す")

    reviewFailure = .unreachable
    state.reviewDraft.body = "直してください"
    state.chooseReviewEvent(.requestChanges)
    panel.submitReview()
    XCTAssertEqual(state.submissionFailure, .unreachable)
    XCTAssertEqual(
      state.reviewDraft, PullRequestState.ReviewDraft(body: "直してください", event: .requestChanges))
  }

  /// 保留中のコメントがあれば、全体へのコメントが空でも「コメント」で送れる。
  func testPendingCommentsCanBeSubmittedWithoutABody() throws {
    pendingComments = 2
    _ = try reviewed()
    XCTAssertTrue(panel.canSubmitReview)
    panel.submitReview()
    XCTAssertEqual(reviewWrites, [.submit(.comment, body: "")])
  }

  /// 自分の PR では「承認」と「変更を依頼」を選べない。
  func testTheAuthorCannotApproveOrRequestChanges() throws {
    viewerIsAuthor = true
    let state = try reviewed()
    XCTAssertFalse(state.canChoose(.approve))
    XCTAssertFalse(state.canChoose(.requestChanges))
    XCTAssertTrue(state.canChoose(.comment))
    state.chooseReviewEvent(.approve)
    XCTAssertEqual(state.reviewDraft.event, .comment)
  }

  /// ファイルのコメント数は、今の diff に置けるスレッドのコメントの総数。置けないスレッドは件数だけを数える。
  func testCommentCountsCoverPlaceableThreadsOnly() throws {
    threads = [
      thread("T1", path: "README.md", line: 2, comments: 2),
      thread("T2", path: "README.md", line: nil, comments: 3),
      thread("T3", path: "src/b.swift", line: 1, comments: 1),
    ]
    let state = try reviewed()
    XCTAssertEqual(panel.commentCount(of: "README.md"), 2)
    XCTAssertEqual(panel.commentCount(of: "src/b.swift"), 1)
    XCTAssertEqual(panel.commentCount(of: "src/a/x.swift"), 0)
    XCTAssertEqual(state.outdatedThreadCount, 1)
  }

  /// 空白と改行だけの全体へのコメントは空とみなす——「コメント」は送れず、「承認」は本文なしで送る。
  func testABlankBodyCountsAsEmpty() throws {
    let state = try reviewed()
    state.reviewDraft.body = " \n\t "
    XCTAssertFalse(panel.canSubmitReview)
    state.chooseReviewEvent(.approve)
    XCTAssertTrue(panel.submitReview())
    XCTAssertEqual(reviewWrites, [.submit(.approve, body: "")])
  }

  /// 中身とレビューのやりとりの先頭のコミットが違う間は送れず、その理由を出す（承認を、diff で見ていないコミットに付けない）。
  func testAReviewOfAnotherHeadCannotBeSubmitted() throws {
    reviewHead = String(repeating: "0", count: 40)
    let state = try reviewed()
    state.chooseReviewEvent(.approve)
    XCTAssertFalse(panel.canSubmitReview)
    XCTAssertEqual(state.submissionBlock, .stopped, "揃える読みでも食い違ったので、再読込を促す")
    XCTAssertFalse(panel.submitReview())
    XCTAssertEqual(reviewWrites, [])
  }

  /// diff の両端を求められない PR は送れず、その理由を出す（diff を見られない PR を Orbe から承認しない）。
  func testAReviewWithoutADiffCannotBeSubmitted() throws {
    head = String(repeating: "1", count: 40)
    reviewHead = head
    let state = try shown()
    pumpMain(
      until: {
        guard state.review != nil, case .failed = state.bounds else { return false }
        return true
      }, "前提: diff の両端を求められない")
    state.chooseReviewEvent(.approve)
    XCTAssertEqual(state.submissionBlock, .noDiff)
    XCTAssertFalse(panel.submitReview())
    XCTAssertEqual(reviewWrites, [])
  }

  /// レビューのやりとりが diff の両端より先に届いても、両端が揃えば、古い側の行のスレッドをファイルの行の数に入れて
  /// 描き直す。
  func testCommentCountsFollowTheDiffEndsThatArriveAfterTheReview() throws {
    threads = [thread("T1", path: "README.md", line: 1, comments: 2, side: .old)]
    let state = try shown()
    pumpMain(until: { state.review != nil }, "前提: レビューのやりとりが届く")
    XCTAssertNil(state.diffEnds, "前提: 両端はまだ求めている")
    XCTAssertEqual(panel.commentCount(of: "README.md"), 0, "両端が分からない間は古い側を数えない")
    let before = panel.rowsVersion
    pumpMain(until: { state.diffEnds != nil }, "両端が揃う")
    XCTAssertNotEqual(panel.rowsVersion, before, "見えている行を描き直す")
    XCTAssertEqual(panel.commentCount(of: "README.md"), 2)
  }

  /// 置けないスレッドの件数は未解決のものだけを数える。
  func testOutdatedThreadsCountOnlyUnresolvedOnes() throws {
    threads = [
      thread("T1", path: "README.md", line: nil, comments: 1),
      thread("T2", path: "README.md", line: nil, comments: 1, resolved: true),
    ]
    let state = try reviewed()
    XCTAssertEqual(state.outdatedThreadCount, 1)
  }

  private func thread(
    _ id: String, path: String, line: Int?, comments: Int, resolved: Bool = false,
    side: GitHubDiffSide = .new
  ) -> GitHubPullRequestReview.Thread {
    GitHubPullRequestReview.Thread(
      id: id, path: path, side: side, line: line, isResolved: resolved, canReply: true,
      canResolve: true, canUnresolve: false,
      comments: (0..<comments).map {
        .init(id: "\(id)-\($0)", author: "me", body: "本文", createdAt: Date(), isPending: false)
      })
  }
}
