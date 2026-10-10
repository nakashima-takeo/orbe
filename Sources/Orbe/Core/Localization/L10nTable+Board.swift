import Foundation

/// ボードの文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let boardTable: [L10nKey: (ja: String, en: String)] = [
    .boardEmpty: ("まだ何も置かれていません", "Nothing here yet"),
    .boardIntakeTitle: ("タスクの自動追加", "Task auto-add"),
    .boardIntakeCount: ("%lld 件", "%lld"),
    .boardIntakeEmpty: ("タスクの自動追加はまだありません", "No task auto-adds yet"),
    .boardIntakeJudge: ("判定の指示", "Judge instruction"),
    .boardIntakeWhen: ("いつ", "When"),
    .boardIntakeRuns: ("回の記録", "Runs"),
    .boardIntakePausedNote: ("（止めている）", " (paused)"),
    .boardHintSelect: ("選択", "select"),
    .boardHintToList: ("一覧へ", "to list"),
    .boardHintCancel: ("やめる", "cancel"),
    .boardAskPlaceholder: (
      "やりたいことを入力（例: Slack の自分宛ての DM をタスクの候補にして）",
      "Describe what you want (e.g. Turn my Slack DMs into task candidates)"
    ),
    .boardAskHint: ("依頼", "ask"),
    .boardAskFixTag: ("「%@」を直す", "Fix “%@”"),
    .boardAskFixPlaceholder: ("直したいことを入力（無くてもよい）", "What to fix (optional)"),
    .boardAskFixHint: ("直しを依頼", "ask to fix"),
    .boardAskClaudeMissing: (
      "claude が見つからないので依頼できない", "claude not found, so the request was not sent"
    ),
    .boardAskFixGone: ("その自動追加はもうありません", "That auto-add no longer exists"),
  ]
}
