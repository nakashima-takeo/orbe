import Foundation

/// 「GitHub から読めていない」知らせ——3 つの読み（今のブランチの PR の引き直し・PR の中身・レビューのやりとり）の失敗を
/// まとめた 1 つの知らせと、人がそれを閉じた印。印は知らせの単位で worktree の今の PR が、閉じたときの PR に結んで持つ
/// （今の PR が替われば効かない。PR の head のブランチを取り出せる worktree は 1 つなので、同じ PR を出す面はどれも同じ印を
/// 読む）。
extension BranchPullRequest {
  /// 人が今の PR の「GitHub から読めていない」知らせを閉じている。
  var isReadingFailureDismissed: Bool {
    readingFailureDismissedState != nil && readingFailureDismissedState === state
  }

  /// 3 つの読みのどれかが失敗している。
  var isReadingFailed: Bool {
    lookupFailure != nil || state?.contentFailure != nil || state?.reviewFailure != nil
  }

  /// 知らせを閉じる——印を付け、失敗の値は次に読めるまで残す。印は、読めていない状態が終わる（3 つの読みのどれも失敗して
  /// いない）か、人が読み直しを頼むか、今の PR が替わるまで残る。一部の読みだけが通っても、別の読みが初めて失敗しても、
  /// 知らせを出し直さない。
  func dismissReadingFailure() {
    guard isReadingFailed else { return }
    readingFailureDismissedState = state
  }

  /// 印を外す（人が頼んだ読み直し）。
  func clearReadingFailureDismissal() {
    readingFailureDismissedState = nil
  }

  /// 読みの失敗か今の PR が変わりうる（引き直しの答え・PR ごとの状態の知らせ）。読めていない状態が終わった・今の PR が
  /// 替わったなら印を外す（後で同じ PR へ戻っても、閉じた印を引き継がない）。
  func readingFailuresDidChange() {
    guard let dismissed = readingFailureDismissedState else { return }
    if dismissed !== state || !isReadingFailed { readingFailureDismissedState = nil }
  }
}
