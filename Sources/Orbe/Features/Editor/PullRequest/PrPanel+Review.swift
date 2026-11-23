import Foundation

/// PR のパネルの下端の区画から送るレビュー——送れるかの判定と送信。規則は PR ごとの状態が持ち
/// （→ `PullRequestState+Submission`）、ここは全体へのコメント欄の変換中の字（IME でまだ確定していない字）を渡すだけ。
extension PrPanel {
  /// 欄に見えている字（書きかけと変換中の字）で送れるか。
  var canSubmitReview: Bool { state?.canSubmitReview(composing: reviewComposition) ?? false }

  /// 送る。欄が変換中なら先に確定する（確定した字が書きかけに入るので、欄に見えていた字で決めた可否と、送る本文が揃う）。
  /// 送れなければ何もせず false を返す。
  @discardableResult
  func submitReview() -> Bool {
    confirmReviewComposition()
    return state?.submitReview { _ in } ?? false
  }
}
