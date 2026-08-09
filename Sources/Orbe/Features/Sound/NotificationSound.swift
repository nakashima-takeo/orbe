import Foundation

/// エージェントの状態変化で鳴らす通知音の音案（12 案）。並びはそのまま設定サブパレットの行順。
/// 実際の合成定義は `SoundCatalog`、鳴らすかどうかの判断は `AgentSoundDecision`。
enum NotificationSound: String, CaseIterable {
  case glass, pulse, wood, air, emblem, henji, hazumi, yuugi, hagane, youkin, kuchibue, deep

  /// 未設定時に鳴る音案。**リテラルを 2 箇所に書かない**——実機で 12 案を聴き比べて決め直すとき、
  /// 差し替えがこの 1 行で済むようにしてある（descriptor の既定値もここを参照する）。
  static let `default`: NotificationSound = .glass

  /// 設定パレット行・descriptor display の表示ラベル（`EmojiFontMode.labelKey` 前例＝案自身が名乗る）。
  /// 並行配列で位置結合するとラベル取り違えが黙って通るため、写像はここ 1 箇所に持つ。
  var labelKey: L10nKey {
    switch self {
    case .glass: return .soundGlass
    case .pulse: return .soundPulse
    case .wood: return .soundWood
    case .air: return .soundAir
    case .emblem: return .soundEmblem
    case .henji: return .soundHenji
    case .hazumi: return .soundHazumi
    case .yuugi: return .soundYuugi
    case .hagane: return .soundHagane
    case .youkin: return .soundYoukin
    case .kuchibue: return .soundKuchibue
    case .deep: return .soundDeep
    }
  }
}

extension NotificationSound: SettingConvertible {
  init?(settingValue: SettingValue) {
    guard case .string(let raw) = settingValue, let sound = NotificationSound(rawValue: raw) else {
      return nil
    }
    self = sound
  }
  var settingValue: SettingValue { .string(rawValue) }
}

/// 音を鳴らすエージェント状態。design の `error` は Orbe に対応する状態が無いので持たない。
/// rawValue は `report_agent` の state 文字列そのもの——これ以外の状態は鳴らさない（＝`init?(rawValue:)` が nil）。
enum AgentSoundEvent: String, CaseIterable {
  case done, waiting

  /// 試聴対象のセグメント表示に使うラベル（状態名の語彙をそのまま共有する）。
  var labelKey: L10nKey {
    switch self {
    case .done: return .agentStateDone
    case .waiting: return .agentStateWaiting
    }
  }
}
