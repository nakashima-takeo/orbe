import Foundation
import OrbeSound

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

  /// waiting / done 以外の状態・通知音オフは鳴らさない（nil）。
  /// 「鳴らない」の担体はオン/オフただ 1 つ——音量は 5% を下限に持ち、無音になる値を取らない。
  static func plan(state: String, settings: EffectiveSettings) -> Plan? {
    guard let event = AgentSoundEvent(rawValue: state) else { return nil }
    guard settings[SettingKeys.notificationSoundEnabled] else { return nil }
    return Plan(
      family: settings[SettingKeys.notificationSound], event: event,
      volume: settings[SettingKeys.notificationSoundVolume])
  }
}
