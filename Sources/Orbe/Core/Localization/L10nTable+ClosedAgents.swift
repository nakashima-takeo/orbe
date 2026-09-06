import Foundation

/// 閉じたエージェント パレット（⇧⌘T）ドメインの文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let closedAgentsTable: [L10nKey: (ja: String, en: String)] = [
    .closedAgentsEmpty: (
      "この workspace で閉じたエージェントはありません", "No closed agents in this workspace"
    ),
    .closedAgentsHintRestore: ("復元", "Restore"),
    .closedAgentsHintDrill: ("中身", "Contents"),
    .closedAgentsHintRestoreOne: ("この 1 件を復元", "Restore this one"),
    .closedAgentsHintBack: ("戻る", "Back"),
    .closedAgentsHintSelect: ("選択", "Select"),
    .closedAgentsHintClose: ("閉じる", "Close"),
    .closedAgentsGroupCount: ("%lld 件", "%lld sessions"),
    // 終わり方のバッジ。色でなく語で語る。
    .closedAgentsOriginGesture: ("自分で閉じた", "closed by you"),
    .closedAgentsOriginProcess: ("落ちた", "crashed"),
    .closedAgentsOriginAgent: ("終了した", "ended"),
    .closedAgentsOriginControlAPI: ("外部から閉じた", "closed via API"),
    .closedAgentsOriginUnresolved: ("resume できなかった", "could not resume"),
  ]
}
