import Foundation

/// PR の画面の、上のバーの右下の置き場に出す失敗の札。人に見える失敗の単位——GitHub から読めていない・確認済みの書き込みが
/// GitHub に通らない・レビューを送信できない——ごとに 1 枚。
struct PrFailureCard {
  enum Kind: Hashable {
    /// 中身の読み・今のブランチの PR の引き直し・レビューのやりとりの読みの失敗（3 つをまとめて 1 枚にする）。
    case reading
    case viewed
    case submission
  }

  let kind: Kind
  let text: String
  /// × を押した——失敗の持ち主の閉じる口を呼ぶ。
  let dismiss: () -> Void
}

/// PR の画面の失敗の札の列の導出。worktree の今の PR・その PR ごとの状態・この面のレビューのポップアップが開いているかを
/// 読むだけで、どれも観測できる値なので、置き場が描画の中で呼べば、知らせの経路に乗らない変化も取りこぼさない。札を出すのは、
/// PR があって中身が読めている間だけ（中身がまだ読めていない間の失敗は、本体の表示が出す）。
@MainActor
enum PrFailureCards {
  /// 上から出す順の札——読めていない・確認済み・送信。読めていない札の文は、読みの失敗のうち、中身・引き直し・レビューの
  /// やりとりの順で最初のもので、× は知らせを閉じる（→ `BranchPullRequest+ReadingFailure`）。送信の札は、ポップアップが開いている間は出さない
  /// （ポップアップの下端の帯に出す）。
  static func cards(
    of pullRequest: BranchPullRequest, reviewIsOpen: Bool, _ l10n: LocalizationStore
  ) -> [PrFailureCard] {
    guard let state = pullRequest.state, state.content != nil else { return [] }
    var cards: [PrFailureCard] = []
    if let text = readingText(pullRequest, state, l10n) {
      cards.append(
        PrFailureCard(kind: .reading, text: text) { [weak pullRequest] in
          pullRequest?.dismissReadingFailure()
        })
    }
    if let failure = state.viewedFailure {
      cards.append(
        PrFailureCard(kind: .viewed, text: viewedText(failure, l10n)) { [weak state] in
          state?.dismissViewedFailure()
        })
    }
    if let failure = state.submissionFailure, !reviewIsOpen {
      cards.append(
        PrFailureCard(kind: .submission, text: submissionText(failure, l10n)) { [weak state] in
          state?.dismissSubmissionFailure()
        })
    }
    return cards
  }

  private static func readingText(
    _ pullRequest: BranchPullRequest, _ state: PullRequestState, _ l10n: LocalizationStore
  ) -> String? {
    guard !pullRequest.isReadingFailureDismissed else { return nil }
    if let failure = state.contentFailure { return PrPanelText.contentFailure(failure, l10n) }
    if let failure = pullRequest.lookupFailure { return PrPanelText.unavailable(failure, l10n) }
    if let failure = state.reviewFailure { return PrPanelText.reviewReadFailure(failure, l10n) }
    return nil
  }

  /// 確認済みの書き込みの失敗の文。時間切れは、GitHub の今の値を読み直すことを告げる（GitHub が受けていることがあり、状態が
  /// その場で中身を読み直す）。
  private static func viewedText(_ failure: GitHubFailure, _ l10n: LocalizationStore) -> String {
    if failure == .timedOut { return l10n.string(.editorPrViewedTimedOut) }
    return l10n.format(.editorPrViewedFailed, PrPanelText.viewedFailure(failure, l10n))
  }

  /// 送信の失敗の文。時間切れは、送ったレビューが反映されたかを GitHub で確かめるよう告げる。
  private static func submissionText(_ failure: GitHubFailure, _ l10n: LocalizationStore) -> String
  {
    if failure == .timedOut { return l10n.string(.editorPrSubmitTimedOut) }
    return l10n.format(.editorPrSubmitFailed, PrPanelText.writeFailure(failure, l10n.language))
  }
}
