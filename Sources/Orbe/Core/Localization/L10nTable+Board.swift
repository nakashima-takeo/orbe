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
    .boardRoleTrigger: ("トリガー", "When"),
    .boardRoleSource: ("取得元", "Source"),
    .boardRoleOrbe: ("Orbe", "Orbe"),
    .boardRoleStep: ("処理 %lld", "Step %lld"),
    .boardRoleOutput: ("出力先", "Output"),
    .boardOrbeSeen: ("既に見たものを除く", "Skip what was already seen"),
    .boardOutputTaskCandidates: ("タスク候補", "Task candidates"),
    .boardOutputCommand: ("コマンド", "Command"),
    .boardOutputReport: ("報告", "Report"),
    .boardOutputNotifyMenuBar: ("通知：メニューバー", "Notify: menu bar"),
    .boardOutputNotifyNotificationCenter: ("通知：通知センター", "Notify: Notification Center"),
    .boardOutputTally: (
      "これまでに採用 %1$lld件 / 見送り %2$lld件", "So far %1$lld accepted / %2$lld dismissed"
    ),
    .boardRunFailed: ("失敗：%@", "failed: %@"),
    .boardRunFailedShort: ("失敗", "failed"),
    .boardRunAdded: ("%lld件を追加", "added %lld"),
    .boardRunAddedTo: ("%1$lld件を%2$@に追加", "added %1$lld to %2$@"),
    .boardRunNothingNew: ("新着なし", "nothing new"),
    .boardRunAllDropped: ("処理 %lld ですべて除外", "all dropped in step %lld"),
    .boardRunNoneAdded: ("追加なし", "none added"),
    .boardRunDone: ("完了", "done"),
    .boardRunNothingToReport: ("報告なし", "nothing to report"),
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
    .boardExampleGitHub: (
      "毎日 9:00 と 13:00 に、レビューを頼まれた GitHub の PR をタスク候補にする",
      "At 9:00 and 13:00 every day, make the GitHub PRs I’m asked to review task candidates"
    ),
    .boardExampleDailyNote: (
      "毎晩23時に ~/bin/daily-note.sh を実行する", "Run ~/bin/daily-note.sh every night at 23:00"
    ),
    .boardHintSelect: ("移動", "move"),
    .boardHintToList: ("一覧へ", "to list"),
    .boardAskPlaceholder: ("自動化したいことを入力（例：%@）", "Describe what to automate (e.g. %@)"),
    .boardAskHint: ("依頼する", "ask"),
    .boardAskFixHint: ("修正を依頼", "ask to fix"),
    .boardAskClaudeMissing: (
      "claude が見つからないので依頼できない", "claude not found, so the request was not sent"
    ),
    .boardAskFixGone: ("その自動化はもうありません", "That automation no longer exists"),
  ]
}
