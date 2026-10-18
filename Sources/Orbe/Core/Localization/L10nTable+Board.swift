import Foundation

/// ボードの文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let boardTable: [L10nKey: (ja: String, en: String)] = [
    .boardEmpty: ("まだ何も置かれていません", "Nothing here yet"),
    .boardAutomationTitle: ("自動化", "Automations"),
    .boardAutomationEmpty: ("自動化はまだありません", "No automations yet"),
    .boardAutomationLast: ("前回 %1$@　%2$@", "Last %1$@  %2$@"),
    .boardAutomationFlow: ("流れ", "Flow"),
    .boardAutomationCounts: ("前回の件数", "Last counts"),
    .boardAutomationRuns: ("実行履歴", "Runs"),
    .boardOutputTaskCandidates: ("タスク候補", "Task candidates"),
    .boardOutputCommand: ("コマンド", "Command"),
    .boardOutputReport: ("報告", "Report"),
    .boardOutputNotify: ("通知：%@", "Notify: %@"),
    .boardNotifyTitle: ("通知", "Notifications"),
    .boardNotifyOff: ("通知しない", "Off"),
    .boardNotifyMenuBar: ("メニューバー", "Menu bar"),
    .boardNotifyNotificationCenter: ("通知センター", "Notification Center"),
    .boardOutputTally: (
      "これまでに採用 %1$lld件 / 見送り %2$lld件", "So far %1$lld accepted / %2$lld dismissed"
    ),
    .boardRunFailed: ("失敗：%@", "failed: %@"),
    .boardRunFailedShort: ("失敗", "failed"),
    .boardRunAdded: ("%lld件を追加", "added %lld"),
    .boardRunAddedTo: ("%1$lld件を%2$@に追加", "added %1$lld to %2$@"),
    .boardRunNothingNew: ("新着なし", "nothing new"),
    .boardRunNoneAdded: ("追加なし", "none added"),
    .boardRunDone: ("完了", "done"),
    .boardRunNothingToReport: ("報告なし", "nothing to report"),
    .boardRunNothingDone: ("何もしなかった", "nothing done"),
    .boardRunNothingDoneBecause: ("何もしなかった：%@", "nothing done: %@"),
    .boardRunMark: ("%1$@ に%2$@", "%2$@ at %1$@"),
    .boardRunMarkAdded: ("%1$@ に %2$lld件を追加", "added %2$lld at %1$@"),
    .boardRunMarkReported: ("%@ に報告", "reported at %@"),
    .boardGuideLead: (
      "いつ、何をしてほしいかを一文で送ると、左の一覧に加わります。",
      "Send when and what you want in one sentence, and it joins the list on the left."
    ),
    .boardGuideExamples: ("入力例", "Examples"),
    .boardExampleSlack: (
      "自分宛ての Slack DM を10分ごとに確認して、依頼だけをタスク候補にする",
      "Check my Slack DMs every 10 minutes and make only the requests task candidates"
    ),
    .boardExampleReviewDigest: (
      "平日 9:00 に、レビュー待ちの PR をまとめて Slack の #dev-me に投稿する",
      "At 9:00 on weekdays, post a digest of the PRs waiting for my review to #dev-me on Slack"
    ),
    .boardExampleDailyNote: (
      "毎晩23時に ~/bin/daily-note.sh を実行する", "Run ~/bin/daily-note.sh every night at 23:00"
    ),
    .boardHintSelect: ("移動", "move"),
    .boardHintToList: ("一覧へ", "to list"),
    .boardHintChoose: ("決定", "Choose"),
    .boardHintBack: ("戻る", "Back"),
    .boardAskPlaceholder: ("自動化したいことを入力（例：%@）", "Describe what to automate (e.g. %@)"),
    .boardAskHint: ("依頼する", "ask"),
    .boardAskFixHint: ("修正を依頼", "ask to fix"),
    .boardAskClaudeMissing: (
      "claude が見つからないので依頼できない", "claude not found, so the request was not sent"
    ),
    .boardAskUnavailable: ("依頼できなかった", "Couldn’t send the request"),
    .boardAskFixGone: ("その自動化はもうありません", "That automation no longer exists"),
    .boardPartInbox: ("溜まり %lld", "inbox %lld"),
  ]
}
