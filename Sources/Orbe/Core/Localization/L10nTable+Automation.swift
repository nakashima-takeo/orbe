import Foundation

/// 自動化の文言分冊（⌘⇧X の提案タブの文と、⌘⇧X とボードが共有する自動化の文）。本体 `L10n.table` が結合する。
extension L10n {
  static let automationTable: [L10nKey: (ja: String, en: String)] = [
    .taskPaletteTabAutomation: ("提案", "Proposals"),
    .taskPaletteAutomationPlaceholder: ("候補を絞り込み", "Filter candidates"),
    .taskPaletteAutomationAll: ("すべて", "All"),
    .taskPaletteAutomationAskBoard: (
      "自動追加を足す・変えるのは Home のボードから頼む",
      "To add or change auto-adds, ask from the Home board"
    ),
    .taskPaletteAutomationNoProposals: ("候補なし", "no candidates"),
    .taskPaletteAutomationLastFailed: ("前回は失敗", "last run failed"),
    .taskPaletteAutomationContents: ("中身", "Details"),
    .taskPaletteAutomationEmpty: ("候補はありません", "No candidates"),
    .taskPaletteAutomationOpenLink: ("%@ で開く", "Open on %@"),
    .taskPaletteAutomationAsTask: ("タスクにすると", "As a task"),
    .taskPaletteAutomationDismiss: ("捨てる", "Dismiss"),
    .taskPaletteAutomationActionAccept: ("%1$@ をタスクにする", "Make %1$@ a task"),
    .taskPaletteAutomationActionProposals: ("候補の一覧へ", "Back to candidates"),
    .taskPaletteAutomationActionRunNow: ("%1$@ を今すぐ実行", "Run %1$@ now"),
    .taskPaletteAutomationHintShelf: ("棚へ", "shelf"),
    .taskPaletteAutomationHintPick: ("自動追加", "auto-add"),
    .taskPaletteAutomationHintBack: ("候補へ", "candidates"),
    .taskPaletteAutomationLast: ("前回", "Last run"),
    .taskPaletteAutomationOverlaps: ("重なり", "Overlaps"),
    .taskPaletteAutomationOverlapCount: ("%1$@ と %2$lld 件", "%2$lld with %1$@"),
    .taskPaletteAutomationRewriteNote: (
      "名前・取得元・処理は、ボードから頼むと agent がまとめて書き換える",
      "Ask from the board, and an agent rewrites the name, source, and steps together"
    ),
    .taskPaletteAutomationErrAccept: ("タスクにできませんでした", "Couldn’t make it a task"),

    // MARK: 自動化の共有の文
    .automationFetch: ("取得", "Fetch"),
    .automationSteps: ("処理", "Steps"),
    .automationNext: ("次回 %@", "next %@"),
    .automationPaused: ("停止中", "paused"),
    .automationRunning: ("実行中…", "running…"),
    .automationRunAt: ("%@ の回", "%@ run"),
    .automationFetched: ("%lld 件取得", "fetched %lld"),
    .automationProcessed: ("新しい %lld 件を処理", "processed %lld new"),
    .automationProposedShortOne: ("候補 %lld", "%lld candidate"),
    .automationProposedShortOther: ("候補 %lld", "%lld candidates"),
    .automationProposedLongOne: ("候補 %lld 件", "%lld candidate"),
    .automationProposedLongOther: ("候補 %lld 件", "%lld candidates"),
    .automationNothingNew: ("新しい項目なし", "nothing new"),
    .automationFailed: ("失敗 — %@", "failed — %@"),
    .automationNeverRan: ("まだ回っていない", "not run yet"),
    .automationNowMark: ("今すぐ", "now"),
    .automationToday: ("今日", "today"),
    .automationDue: ("期限 %1$@（%2$@）", "Due %1$@ (%2$@)"),
    .automationCurrentSet: (
      "今の集合 · 取得から消えた候補を下げる",
      "Current set · drops candidates that leave the fetch"
    ),
    .automationNewArrivals: (
      "新着の流れ · 判定が対応済みとした候補だけを下げる",
      "New arrivals · drops candidates only when the judge resolves them"
    ),
    .automationEverything: (
      "毎回全件 · 前回の取得結果との差分を掛けない",
      "Everything · no diff against the last fetch"
    ),
    .automationAgentFetch: ("軽い agent", "Light agent"),
    .automationCommand: ("コマンド", "Command"),
    .automationTools: ("使えるツール", "Tools"),
    .automationDirectory: ("作業ディレクトリ", "Directory"),
    .automationEvery: ("%lld分ごと", "every %lld min"),
    .automationDaily: ("毎日", "daily"),
    .automationWeekdays: ("平日", "weekdays"),
    .automationWeekends: ("土日", "weekends"),
    .automationWeekly: ("毎週%@曜", "every %@"),
    .automationMonthly: ("毎月%@", "monthly on day %@"),
    .automationMonthDay: ("%lld日", "%lld"),
    .automationListSeparator: ("・", ", "),
    .automationAt: ("%@", "at %@"),
    .automationHourly: ("毎時%lld分", "hourly at :%02lld"),
    .automationEveryMinutesBetween: ("%1$@〜%2$@ の%3$lld分ごと", "every %3$lld min, %1$@–%2$@"),
    .automationEveryHoursBetween: ("%1$@〜%2$@ の%3$lld時間ごと", "every %3$lld h, %1$@–%2$@"),
    .automationRunNow: ("今すぐ実行", "Run now"),
    .automationPause: ("停止", "Pause"),
    .automationResume: ("再開", "Resume"),
    .automationDelete: ("削除", "Delete"),
    .automationErrRunning: ("実行中のため今すぐ実行できません", "Already running — can’t run now"),
  ]
}
