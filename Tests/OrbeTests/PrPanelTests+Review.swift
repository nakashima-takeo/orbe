import XCTest

@testable import Orbe

/// PR のパネルの下端の区画とファイルの行のコメント数。壊れると何が起きるか: 空のコメントを送信できる・行に書いた保留中の
/// コメントを本文なしで送れない・自分の PR を承認できるように見える・失敗した送信で書きかけが消える・成功した後も書きかけと
/// 選んだ種類が残る・古い版の行のスレッドをコメント数に数える・今の diff に出せないスレッドに気づけない。
extension PrPanelTests {
  /// 「コメント」「変更を依頼」は本文も保留中のコメントも無ければ送れず、「承認」は空でも送れる。送信が成功すれば書きかけは空になり種類は
  /// 「コメント」に戻る。成功しなければ書きかけと種類が残り、失敗を保持する。
  func testSubmittingAReviewNeedsABodyUnlessApprovingAndKeepsTheDraftOnFailure() throws {
    let state = try reviewed()
    XCTAssertFalse(panel.canSubmitReview, "空のコメントは送れない")
    panel.chooseReviewEvent(.requestChanges)
    XCTAssertFalse(panel.canSubmitReview, "空の変更の依頼は送れない")
    panel.chooseReviewEvent(.approve)
    XCTAssertTrue(panel.canSubmitReview, "承認は空でも送れる")
    state.reviewDraft.body = "見ました"
    panel.submitReview()
    XCTAssertEqual(reviewWrites, [.submit(.approve, body: "見ました")])
    XCTAssertEqual(
      state.reviewDraft, PullRequestState.ReviewDraft(), "成功すれば書きかけを空にし、種類を「コメント」に戻す")

    reviewFailure = .unreachable
    state.reviewDraft.body = "直してください"
    panel.chooseReviewEvent(.requestChanges)
    panel.submitReview()
    XCTAssertEqual(panel.state?.submissionFailure, .write(.unreachable))
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
    _ = try reviewed()
    XCTAssertFalse(panel.canChoose(.approve))
    XCTAssertFalse(panel.canChoose(.requestChanges))
    XCTAssertTrue(panel.canChoose(.comment))
    panel.chooseReviewEvent(.approve)
    XCTAssertEqual(panel.state?.reviewDraft.event, .comment)
  }

  /// ファイルのコメント数は、今の diff に置けるスレッドのコメントの総数。置けないスレッドは件数だけを数える。
  func testCommentCountsCoverPlaceableThreadsOnly() throws {
    threads = [
      thread("T1", path: "README.md", line: 2, comments: 2),
      thread("T2", path: "README.md", line: nil, comments: 3),
      thread("T3", path: "src/b.swift", line: 1, comments: 1),
    ]
    _ = try reviewed()
    XCTAssertEqual(panel.commentCount(of: "README.md"), 2)
    XCTAssertEqual(panel.commentCount(of: "src/b.swift"), 1)
    XCTAssertEqual(panel.commentCount(of: "src/a/x.swift"), 0)
    XCTAssertEqual(panel.outdatedThreadCount, 1)
  }

  private func thread(_ id: String, path: String, line: Int?, comments: Int)
    -> GitHubPullRequestReview.Thread
  {
    GitHubPullRequestReview.Thread(
      id: id, path: path, side: .new, line: line, isResolved: false, canReply: true,
      canResolve: true, canUnresolve: false,
      comments: (0..<comments).map {
        .init(id: "\(id)-\($0)", author: "me", body: "本文", createdAt: Date(), isPending: false)
      })
  }
}
