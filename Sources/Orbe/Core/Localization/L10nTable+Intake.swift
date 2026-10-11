import Foundation

/// 自動追加の文言分冊（⌘⇧X の自動追加タブの文と、⌘⇧X とボードが共有する自動追加の文）。本体 `L10n.table` が結合する。
extension L10n {
  static let intakeTable: [L10nKey: (ja: String, en: String)] = [
    .taskPaletteTabIntake: ("自動追加", "Auto-add"),
    .taskPaletteIntakePlaceholder: ("候補を絞り込み", "Filter candidates"),
    .taskPaletteIntakeAskSecretary: (
      "自動追加を足す・変えるのは秘書に頼む",
      "Ask the secretary to add or change auto-adds"
    ),
    .taskPaletteIntakeNoProposals: ("候補なし", "no candidates"),
    .taskPaletteIntakeLastFailed: ("前回は失敗", "last run failed"),
    .taskPaletteIntakeContents: ("中身", "Details"),
    .taskPaletteIntakeEmpty: ("候補はありません", "No candidates"),
    .taskPaletteIntakeOpenLink: ("%@ で開く", "Open on %@"),
    .taskPaletteIntakeAsTask: ("タスクにすると", "As a task"),
    .taskPaletteIntakeDismiss: ("捨てる", "Dismiss"),
    .taskPaletteIntakeActionAccept: ("%1$@ をタスクにする", "Make %1$@ a task"),
    .taskPaletteIntakeActionProposals: ("候補の一覧へ", "Back to candidates"),
    .taskPaletteIntakeActionRunNow: ("%1$@ を今すぐ実行", "Run %1$@ now"),
    .taskPaletteIntakeHintShelf: ("棚へ", "shelf"),
    .taskPaletteIntakeHintPick: ("自動追加", "auto-add"),
    .taskPaletteIntakeHintBack: ("候補へ", "candidates"),
    .taskPaletteIntakeJudge: ("判定", "Judge"),
    .taskPaletteIntakeLast: ("前回", "Last run"),
    .taskPaletteIntakeOverlaps: ("重なり", "Overlaps"),
    .taskPaletteIntakeOverlapCount: ("%1$@ と %2$lld 件", "%2$lld with %1$@"),
    .taskPaletteIntakeRewriteNote: (
      "名前・取得・判定は秘書が一度にまとめて書き換える",
      "The secretary rewrites the name, fetch, and judge together"
    ),
    .taskPaletteIntakeErrAccept: ("タスクにできませんでした", "Couldn’t make it a task"),

    // MARK: 自動追加の共有の文（IntakeText・IntakeHand）
    .intakeFetch: ("取得", "Fetch"),
    .intakeNext: ("次 %@", "next %@"),
    .intakePaused: ("止めている", "paused"),
    .intakeRunning: ("実行中…", "running…"),
    .intakeRunAt: ("%@ の回", "%@ run"),
    .intakeFetched: ("%lld 件取得", "fetched %lld"),
    .intakeJudged: ("新しい %lld 件を判定", "judged %lld new"),
    .intakeProposedShortOne: ("候補 %lld", "%lld candidate"),
    .intakeProposedShortOther: ("候補 %lld", "%lld candidates"),
    .intakeProposedLongOne: ("候補 %lld 件", "%lld candidate"),
    .intakeProposedLongOther: ("候補 %lld 件", "%lld candidates"),
    .intakeNothingNew: ("新しい項目なし", "nothing new"),
    .intakeFailed: ("失敗 — %@", "failed — %@"),
    .intakeFailedShort: ("失敗", "failed"),
    .intakeNeverRan: ("まだ回っていない", "not run yet"),
    .intakeNowMark: ("今すぐ", "now"),
    .intakeToday: ("今日", "today"),
    .intakeDue: ("期限 %1$@（%2$@）", "Due %1$@ (%2$@)"),
    .intakeCurrentSet: (
      "今の集合 · 取得から消えた候補を下げる",
      "Current set · drops candidates that leave the fetch"
    ),
    .intakeNewArrivals: (
      "新着の流れ · 判定が対応済みとした候補だけを下げる",
      "New arrivals · drops candidates only when the judge resolves them"
    ),
    .intakeAgentFetch: ("軽い agent", "Light agent"),
    .intakeCommandFetch: ("コマンド", "Command"),
    .intakeTools: ("使えるツール", "Tools"),
    .intakeDirectory: ("作業ディレクトリ", "Directory"),
    .intakeEvery: ("%lld 分ごと", "every %lld min"),
    .intakeDaily: ("毎日 %@", "daily at %@"),
    .intakeRunNow: ("今すぐ実行", "Run now"),
    .intakePause: ("止める", "Pause"),
    .intakeResume: ("再開", "Resume"),
    .intakeDelete: ("削除", "Delete"),
    .intakeErrRunning: ("実行中のため今すぐ実行できません", "Already running — can’t run now"),
  ]
}
