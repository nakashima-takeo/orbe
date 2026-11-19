import Foundation

/// PR のパネルの下端の区画——全体へのコメントと種類（承認 / コメント / 変更を依頼）を選んで、保留中のコメントとまとめて送る。
/// 書きかけと種類は PR ごとの状態が持ち、送信の結果はパネルが受ける（通れば書きかけを空に、種類を「コメント」に戻し、通らなければ
/// 書きかけを残して失敗の文を出す）。
extension PrPanel {
  /// 種類 `event` を選べるか（自分の PR は承認も変更の依頼もできない。送信の最中は選べない）。
  func canChoose(_ event: GitHubReviewEvent) -> Bool {
    guard let state, let review = state.review, !state.isWritingReview(.submission) else {
      return false
    }
    return event == .comment || !review.viewerIsAuthor
  }

  /// 送れるか——レビューのやりとりが読めていて、送信の最中でなく、選んだ種類を選べ、「承認」でなければ全体へのコメントか保留中の
  /// コメントがある。
  var canSubmitReview: Bool {
    guard let state, let review = state.review else { return false }
    let draft = state.reviewDraft
    guard canChoose(draft.event) else { return false }
    return draft.event == .approve || !draft.body.isEmpty
      || (review.pendingReview?.commentCount ?? 0) > 0
  }

  func chooseReviewEvent(_ event: GitHubReviewEvent) {
    guard let state, canChoose(event) else { return }
    state.reviewDraft.event = event
  }

  /// 送る（送れなければ何もしない——2 回押しても送信は 1 回）。
  func submitReview() {
    guard let state, canSubmitReview else { return }
    reviewFailure = nil
    let draft = state.reviewDraft
    let finished: (GitHubFailure?) -> Void = { [weak self, weak state] failure in
      if let failure {
        self?.reviewFailure = .write(failure)
      } else {
        state?.reviewDraft = PullRequestState.ReviewDraft()
      }
    }
    let accepted = state.writeReview(.submit(draft.event, body: draft.body), completion: finished)
    if !accepted { reviewFailure = .notReady }
  }
}
