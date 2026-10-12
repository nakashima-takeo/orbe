import Foundation

/// ボードの文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let boardTable: [L10nKey: (ja: String, en: String)] = [
    .boardEmpty: ("まだ何も置かれていません", "Nothing here yet"),
    .boardAutomationTitle: ("タスクの自動追加", "Task auto-add"),
    .boardAutomationCount: ("%lld 件", "%lld"),
    .boardAutomationEmpty: ("タスクの自動追加はまだありません", "No task auto-adds yet"),
    .boardAutomationWhen: ("いつ", "When"),
    .boardAutomationRuns: ("回の記録", "Runs"),
    .boardAutomationPausedNote: ("（止めている）", " (paused)"),
    .boardHintSelect: ("選択", "select"),
    .boardHintToList: ("一覧へ", "to list"),
    .boardAskPlaceholder: (
      "やりたいことを入力（例: Slack の自分宛ての DM をタスクの候補にして）",
      "Describe what you want (e.g. Turn my Slack DMs into task candidates)"
    ),
    .boardAskHint: ("依頼", "ask"),
    .boardAskFixHint: ("直しを依頼", "ask to fix"),
    .boardAskClaudeMissing: (
      "claude が見つからないので依頼できない", "claude not found, so the request was not sent"
    ),
    .boardAskFixGone: ("その自動追加はもうありません", "That auto-add no longer exists"),
  ]
}
