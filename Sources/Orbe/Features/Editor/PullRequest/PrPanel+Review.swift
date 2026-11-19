import Foundation

/// PR のパネルの下端の区画——全体へのコメントと種類（承認 / コメント / 変更を依頼）を選んで、保留中のコメントとまとめて送る。
/// 書きかけと種類と送信の失敗は PR ごとの状態が持つ（通れば書きかけを空に、種類を「コメント」に戻し、通らなければ書きかけを
/// 残して失敗の文を出す）。
extension PrPanel {
  /// 種類 `event` を選べるか（自分の PR は承認も変更の依頼もできない。送信の最中は選べない）。
  func canChoose(_ event: GitHubReviewEvent) -> Bool {
    guard let state, let review = state.review, !state.isWritingReview(.submission) else {
      return false
    }
    return event == .comment || !review.viewerIsAuthor
  }

  /// 送れるか——レビューのやりとりが読めていて、中身と同じ先頭のコミットのもので、送信の最中でなく、選んだ種類を選べ、
  /// 「承認」でなければ全体へのコメント（欄に見えている字——変換中の字を含む——で、空白と改行だけなら空）か保留中のコメントが
  /// ある。
  var canSubmitReview: Bool {
    guard let state, let review = state.review, state.isReviewAligned else { return false }
    let draft = state.reviewDraft
    guard canChoose(draft.event) else { return false }
    return draft.event == .approve
      || !(draft.body + reviewComposition).allSatisfy(\.isWhitespace)
      || (review.pendingReview?.commentCount ?? 0) > 0
  }

  /// 中身とレビューのやりとりの先頭のコミットが違うので、送れない（違う間は送信を押せない姿にし、その理由を出す）。
  var awaitsAlignedReview: Bool {
    guard let state, state.review != nil, state.content != nil else { return false }
    return !state.isReviewAligned
  }

  func chooseReviewEvent(_ event: GitHubReviewEvent) {
    guard let state, canChoose(event) else { return }
    state.reviewDraft.event = event
  }

  /// 送る。欄が変換中なら先に確定する（見えていた字が本文に入り、見えている字で決めた可否と送る本文が揃う）。送れなければ
  /// 何もせず false を返す（2 回押しても送信は 1 回）。
  @discardableResult
  func submitReview() -> Bool {
    confirmReviewComposition()
    guard let state, canSubmitReview else { return false }
    state.submissionFailure = nil
    let draft = state.reviewDraft
    let body = draft.body.allSatisfy(\.isWhitespace) ? "" : draft.body
    let finished: (GitHubFailure?) -> Void = { [weak state] failure in
      if let failure {
        state?.submissionFailure = .write(failure)
      } else {
        state?.reviewDraft = PullRequestState.ReviewDraft()
      }
    }
    let accepted = state.writeReview(.submit(draft.event, body: body), completion: finished)
    if !accepted { state.submissionFailure = .notReady }
    return accepted
  }
}
