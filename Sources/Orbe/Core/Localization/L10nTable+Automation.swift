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
    .taskPaletteAutomationNextJudge: ("次の判定 %@", "next judge %@"),
    .taskPaletteAutomationJudgeOnArrival: ("新着が届くたびに判定", "judges each new arrival"),
    .taskPaletteAutomationJudgeManual: ("判定は手動（⌘↵ で更新）", "manual judge (⌘↵ to refresh)"),
    .taskPaletteAutomationRefreshing: ("更新中…", "refreshing…"),
    .taskPaletteAutomationEmpty: ("候補はありません", "No candidates"),
    .taskPaletteAutomationOpenLink: ("%@ で開く", "Open on %@"),
    .taskPaletteAutomationAsTask: ("タスクにすると", "As a task"),
    .taskPaletteAutomationDismiss: ("捨てる", "Dismiss"),
    .taskPaletteAutomationActionAccept: ("%1$@ をタスクにする", "Make %1$@ a task"),
    .taskPaletteAutomationActionProposals: ("候補の一覧へ", "Go to candidates"),
    .taskPaletteAutomationActionRefresh: ("%1$@ の候補を今すぐ更新", "Refresh candidates of %1$@ now"),
    .taskPaletteAutomationHintShelf: ("棚へ", "shelf"),
    .taskPaletteAutomationHintPick: ("自動追加", "auto-add"),
    .taskPaletteAutomationHintProposals: ("候補へ", "candidates"),
    .taskPaletteAutomationErrAccept: ("タスクにできませんでした", "Couldn’t make it a task"),
    .taskPaletteAutomationErrRefreshing: (
      "更新中のため、今は更新できません", "Already refreshing — can’t refresh now"
    ),

    // MARK: 自動化の共有の文
    .automationNext: ("次回 %@", "next %@"),
    .automationPaused: ("停止中", "paused"),
    .automationRunning: ("実行中…", "running…"),
    .automationFailed: ("失敗 — %@", "failed — %@"),
    .automationNeverRan: ("まだ回っていない", "not run yet"),
    .automationFailedPart: ("%@ で失敗", "%@ failed"),
    .automationFailedParts: ("%1$@ ほか %2$lld 件 で失敗", "%1$@ +%2$lld failed"),
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
    .automationFlowHere: ("ここまで今すぐ流す", "Flow here now"),
    .automationErrFlowing: ("実行中のため今すぐ流せません", "Already running — can’t flow now"),
    .automationRoleFetch: ("取得", "Fetch"),
    .automationRoleProcess: ("処理", "Process"),
    .automationRoleJudge: ("判定", "Judge"),
    .automationRoleReport: ("報告", "Report"),
    .automationRoleWork: ("仕事", "Work"),
    .automationRoleSideEffect: ("副作用", "Side effect"),
    .automationManual: ("手動", "manual"),
    .automationArrival: ("届いたら", "on arrival"),
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
