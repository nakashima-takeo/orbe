import Foundation

/// エージェントの状態変化で鳴らす通知音の音案（12 案）。並びはそのまま設定サブパレットの行順。
/// 実際の合成定義は `SoundCatalog`、鳴らすかどうかの判断はアプリ側の `AgentSoundDecision`。
/// 表示ラベル・設定変換などアプリの語彙への橋は Orbe 側の extension（`NotificationSound+App`）が持つ。
public enum NotificationSound: String, CaseIterable, Sendable {
  case glass, pulse, wood, air, emblem, reply, bounce, arcade, steel, piano, whistle, deep

  /// 未設定時に鳴る音案。**リテラルを 2 箇所に書かない**——実機で 12 案を聴き比べて決め直すとき、
  /// 差し替えがこの 1 行で済むようにしてある（descriptor の既定値もここを参照する）。
  public static let `default`: NotificationSound = .emblem
}

/// 音を鳴らすエージェント状態。この 2 状態だけが音の契機で、
/// rawValue は `report_agent` の state 文字列そのもの——これ以外の状態は鳴らさない（＝`init?(rawValue:)` が nil）。
public enum AgentSoundEvent: String, CaseIterable, Sendable {
  case done, waiting
}
