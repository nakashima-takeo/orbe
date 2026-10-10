import Foundation

/// タスク画面（⌘⇧X）の受信タブの文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let intakeTable: [L10nKey: (ja: String, en: String)] = [
    .taskPaletteTabIntake: ("受信", "Intake"),
    .taskPaletteIntakePlaceholder: ("受信を絞り込み", "Filter intake"),
    .taskPaletteIntakeAskSecretary: (
      "受信を足す・変えるのは秘書に頼む",
      "Ask the secretary to add or change intakes"
    ),
    .taskPaletteIntakeNext: ("次 %@", "next %@"),
    .taskPaletteIntakePaused: ("止めている", "paused"),
    .taskPaletteIntakeRunning: ("受信中…", "fetching…"),
    .taskPaletteIntakeNoProposals: ("提案なし", "no proposals"),
    .taskPaletteIntakeLastFailed: ("前回は失敗", "last run failed"),
    .taskPaletteIntakeContents: ("中身", "Details"),
    .taskPaletteIntakeRunAt: ("%@ の回", "%@ run"),
    .taskPaletteIntakeFetched: ("%lld 件取得", "fetched %lld"),
    .taskPaletteIntakeJudged: ("新しい %lld 件を判定", "judged %lld new"),
    .taskPaletteIntakeProposedShort: ("提案 %lld", "proposed %lld"),
    .taskPaletteIntakeProposedLong: ("%lld 件を提案", "proposed %lld"),
    .taskPaletteIntakeNothingNew: ("新しい項目なし", "nothing new"),
    .taskPaletteIntakeFailed: ("失敗 — %@", "failed — %@"),
    .taskPaletteIntakeNeverRan: ("まだ回っていない", "not run yet"),
    .taskPaletteIntakeEmpty: ("提案はありません", "No proposals"),
    .taskPaletteIntakeOpenLink: ("%@ で開く", "Open on %@"),
    .taskPaletteIntakeAsTask: ("タスクにすると", "As a task"),
    .taskPaletteIntakeDue: ("期限 %1$@（%2$@）", "Due %1$@ (%2$@)"),
    .taskPaletteIntakeDismiss: ("捨てる", "Dismiss"),
    .taskPaletteIntakeActionAccept: ("%1$@ をタスクにする", "Make %1$@ a task"),
    .taskPaletteIntakeActionProposals: ("提案の一覧へ", "Back to proposals"),
    .taskPaletteIntakeActionRunNow: ("%1$@ を今すぐ受信", "Fetch %1$@ now"),
    .taskPaletteIntakeHintShelf: ("棚へ", "shelf"),
    .taskPaletteIntakeHintPick: ("受信", "intake"),
    .taskPaletteIntakeHintBack: ("提案へ", "proposals"),
    .taskPaletteIntakeFetch: ("取得", "Fetch"),
    .taskPaletteIntakeCurrentSet: (
      "今の集合 · 取得から消えた提案を下げる",
      "Current set · drops proposals that leave the fetch"
    ),
    .taskPaletteIntakeNewArrivals: (
      "新着の流れ · 判定が対応済みとした提案だけを下げる",
      "New arrivals · drops proposals only when the judge resolves them"
    ),
    .taskPaletteIntakeJudge: ("判定", "Judge"),
    .taskPaletteIntakeLast: ("前回", "Last run"),
    .taskPaletteIntakeOverlaps: ("重なり", "Overlaps"),
    .taskPaletteIntakeAgentFetch: ("軽い agent", "Light agent"),
    .taskPaletteIntakeCommandFetch: ("コマンド", "Command"),
    .taskPaletteIntakeTools: ("使えるツール", "Tools"),
    .taskPaletteIntakeDirectory: ("作業ディレクトリ", "Directory"),
    .taskPaletteIntakeEvery: ("%lld 分ごと", "every %lld min"),
    .taskPaletteIntakeDaily: ("毎日 %@", "daily at %@"),
    .taskPaletteIntakeOverlapCount: ("%1$@ と %2$lld 件", "%2$lld with %1$@"),
    .taskPaletteIntakeRewriteNote: (
      "名前・取得・判定は秘書が一度にまとめて書き換える",
      "The secretary rewrites the name, fetch, and judge together"
    ),
    .taskPaletteIntakeRunNow: ("今すぐ受信", "Fetch now"),
    .taskPaletteIntakePause: ("止める", "Pause"),
    .taskPaletteIntakeResume: ("再開", "Resume"),
    .taskPaletteIntakeErrAccept: ("タスクにできませんでした", "Couldn’t make it a task"),
    .taskPaletteIntakeErrRunning: ("受信中のため今すぐ受信できません", "Already fetching — can’t fetch now"),
  ]
}
