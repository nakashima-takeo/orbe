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
  ]
}
