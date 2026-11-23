import Foundation

/// 読みの失敗——次に読めるまで続く失敗の、最後の読みが失敗した理由と、人がその知らせを閉じた印。この値を持つ側（PR ごとの
/// 状態・worktree の今の PR）は、次に読めたらこの値を消し、続けて失敗したら理由だけを入れ替えて印を保つ（自動の読み直しが
/// 失敗するたびに、閉じた知らせを出し直さない）。印は、人が読み直しを頼んだときに外す。
struct PrReadFailure<Reason: Equatable>: Equatable {
  let reason: Reason
  /// 人が知らせを閉じた。
  var isDismissed: Bool

  /// 前の失敗 `previous`（無ければ nil）に続く失敗 `reason`。閉じた印は前の値から引き継ぐ。
  init(_ reason: Reason, after previous: Self?) {
    self.reason = reason
    isDismissed = previous?.isDismissed ?? false
  }
}

/// PR ごとの状態の読みの失敗（中身とレビューのやりとり）の知らせ。
extension PullRequestState {
  /// 知らせを閉じる——閉じた印を付け、失敗の値は次に読めるまで残す。
  func dismissReadFailures() {
    contentFailure?.isDismissed = true
    reviewFailure?.isDismissed = true
  }

  /// 閉じた印を外す（人が頼んだ読み直し）。
  func clearReadFailureDismissals() {
    contentFailure?.isDismissed = false
    reviewFailure?.isDismissed = false
  }
}

/// worktree の今の PR の、今のブランチの PR を引き直せなかった失敗の知らせ。
extension BranchPullRequest {
  /// 知らせを閉じる——閉じた印を付け、失敗の値は次に答えを出すまで残す。
  func dismissLookupFailure() {
    lookupFailure?.isDismissed = true
  }

  /// 閉じた印を外す（人が頼んだ読み直し）。
  func clearLookupFailureDismissal() {
    lookupFailure?.isDismissed = false
  }
}
