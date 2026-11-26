import Foundation

/// レビューの送信——全体へのコメントと種類（コメント / 承認 / 変更を依頼）を選んで、未送信のコメントとまとめて送る規則。
/// 書きかけと種類と送信の失敗はここが持ち（成功すれば書きかけを空に、種類を「コメント」に戻し、失敗すれば書きかけを残して
/// 失敗を持つ）、送信の入口を出す面は、欄に見えている変換中の字（IME でまだ確定していない字）を渡して問うだけ。
extension PullRequestState {
  struct ReviewDraft: Equatable {
    var body = ""
    var event = GitHubReviewEvent.comment
  }

  /// 選べる種類の並び。レビューのやりとりが読めていなければ空、自分の PR は「コメント」だけ（承認も変更の依頼もできない）。
  var reviewEvents: [GitHubReviewEvent] {
    guard let review else { return [] }
    return review.viewerIsAuthor ? [.comment] : [.comment, .approve, .requestChanges]
  }

  /// 種類 `event` を選べるか（選べる種類の並びに在り、送信の最中でない）。
  func canChoose(_ event: GitHubReviewEvent) -> Bool {
    reviewEvents.contains(event) && !isWritingReview(.submission)
  }

  func chooseReviewEvent(_ event: GitHubReviewEvent) {
    guard canChoose(event) else { return }
    reviewDraft.event = event
  }

  /// 送れるか——diff の両端・中身・レビューのやりとりの版が揃っていて（`isReviewAligned`）、送信の最中でなく、選んだ種類を
  /// 選べ、「承認」でなければ全体へのコメント（書きかけに、欄の変換中の字 `composing` を足したもの。空白と改行だけなら空）か
  /// 未送信のコメントがある。
  func canSubmitReview(composing: String) -> Bool {
    guard let review, isReviewAligned else { return false }
    let draft = reviewDraft
    guard canChoose(draft.event) else { return false }
    return draft.event == .approve
      || !(draft.body + composing).allSatisfy(\.isWhitespace)
      || (review.pendingReview?.commentCount ?? 0) > 0
  }

  /// 送れない理由——diff の両端・中身・レビューのやりとりの版が揃っていない（揃っていなければ送信を押せない姿にし、その理由を
  /// 出す）。中身とレビューのやりとりがまだ読み込めていなければ nil。
  var submissionBlock: SubmissionBlock? {
    guard review != nil, content != nil, !isReviewAligned else { return nil }
    if case .failed = bounds { return .noDiff }
    return stoppedAligning ? .stopped : .loading
  }

  enum SubmissionBlock: Equatable {
    /// 読み込んでいる・diff の両端を求めている。
    case loading
    /// 中身とレビューのやりとりの先頭が食い違ったまま、揃える読みをやめた（再読込で読み直す）。
    case stopped
    /// diff の両端を求められない（diff を見られない PR を承認しない）。
    case noDiff
  }

  /// 送信の失敗を消す（失敗の知らせを閉じた）。
  func dismissSubmissionFailure() {
    submissionFailure = nil
  }

  /// 書きかけを送る（欄の変換中の字は、呼び出し側が先に確定しておく）。送れなければ何もせず false を返す（2 回押しても
  /// 送信は 1 回）。
  /// 受け付けたら前の送信の失敗を消し、終わったときに `completion` へ「成功したか」を 1 回返す。
  @discardableResult
  func submitReview(completion: @escaping (Bool) -> Void) -> Bool {
    guard canSubmitReview(composing: "") else { return false }
    submissionFailure = nil
    let draft = reviewDraft
    let body = draft.body.allSatisfy(\.isWhitespace) ? "" : draft.body
    return writeReview(.submit(draft.event, body: body)) { [weak self] result in
      if let failure = result.failure {
        self?.submissionFailure = failure
      } else {
        self?.reviewDraft = ReviewDraft()
      }
      completion(result.failure == nil)
    }
  }
}
