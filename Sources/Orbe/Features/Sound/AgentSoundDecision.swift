import Foundation

/// 「鳴らすか・何を鳴らすか」の判断（純関数）。設定だけを見るのでテストで全組み合わせを機械検証できる。
///
/// 「見ているタブか」だけはここに入れない——`WindowController` の窓とタブの状態に依存するため、
/// 呼び出し側（`WindowController.noteAgentSound`）が既存の `visibleTab` 判定で先に弾く。
enum AgentSoundDecision {
  struct Plan: Equatable {
    let family: NotificationSound
    let event: AgentSoundEvent
    let volume: Int
  }

  /// waiting / done 以外の状態・通知音オフ・音量 0 は鳴らさない（nil）。
  static func plan(state: String, settings: EffectiveSettings) -> Plan? {
    guard let event = AgentSoundEvent(rawValue: state) else { return nil }
    guard settings[SettingKeys.notificationSoundEnabled] else { return nil }
    let volume = settings[SettingKeys.notificationSoundVolume]
    guard volume > 0 else { return nil }
    return Plan(family: settings[SettingKeys.notificationSound], event: event, volume: volume)
  }
}
