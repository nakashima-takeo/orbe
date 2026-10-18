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
      "名前・部品は、ボードから頼むと agent がまとめて書き換える",
      "Ask from the board, and an agent rewrites the name and the parts together"
    ),
    .taskPaletteAutomationErrAccept: ("タスクにできませんでした", "Couldn’t make it a task"),

    // MARK: 自動化の共有の文
    .automationNext: ("次回 %@", "next %@"),
    .automationPaused: ("停止中", "paused"),
    .automationRunning: ("実行中…", "running…"),
    .automationFailed: ("失敗 — %@", "failed — %@"),
    .automationNeverRan: ("まだ回っていない", "not run yet"),
    .automationNowMark: ("今すぐ", "now"),
    .automationToday: ("今日", "today"),
    .automationDue: ("期限 %1$@（%2$@）", "Due %1$@ (%2$@)"),
    .automationEvery: ("%lld分ごと", "every %lld min"),
    .automationDaily: ("毎日", "daily"),
    .automationWeekdays: ("平日", "weekdays"),
    .automationWeekends: ("土日", "weekends"),
    .automationWeekly: ("毎週%@曜", "every %@"),
    .automationMonthlyOne: ("毎月%@", "monthly on day %@"),
    .automationMonthlyOther: ("毎月%@", "monthly on days %@"),
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
    .automationRoleFetch: ("取得", "Fetch"),
    .automationRoleProcess: ("処理", "Process"),
    .automationRoleJudge: ("判定", "Judge"),
    .automationRoleReport: ("報告", "Report"),
    .automationRoleWork: ("仕事", "Work"),
    .automationRoleSideEffect: ("副作用", "Side effect"),
    .automationManual: ("手動", "manual"),
    .automationArrival: ("届いたら", "on arrival"),
    .automationParts: ("部品", "Parts"),
    .automationFetchedFresh: ("%1$lld 件取得 → 新しい %2$lld 件", "fetched %1$lld → %2$lld new"),
    .automationTakenTo: ("%1$lld 件 → %2$lld 件", "%1$lld → %2$lld"),
    .automationTakenProposedOne: ("%1$lld 件 → 候補 %2$lld", "%1$lld → %2$lld candidate"),
    .automationTakenProposedOther: ("%1$lld 件 → 候補 %2$lld", "%1$lld → %2$lld candidates"),
    .automationOthers: ("%1$@ ほか %2$lld", "%1$@ +%2$lld"),
    .automationBreachOne: (
      "%1$@ の出力が決まりを外した — %2$@（%3$lld 行）",
      "%1$@ broke the output rules — %2$@ (%3$lld line)"
    ),
    .automationBreachOther: (
      "%1$@ の出力が決まりを外した — %2$@（%3$lld 行）",
      "%1$@ broke the output rules — %2$@ (%3$lld lines)"
    ),
    .automationBreachPassed: ("出し直しで通った", "passed on redo"),
    .automationBreachFailed: ("失敗", "failed"),
  ]
}
