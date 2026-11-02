import Foundation

/// 保持の値——ノードごとに残す回の記録（と判定の人の判断の記録）の回数と日数、出来事を残す日数の既定。回の記録は「新しい方から
/// `runCount` 回」か「`runDays` 日以内」のどちらかに入れば残る。出来事の日数は、出す側のノードが `retentionDays` を持たない
/// ときに効く。値は設定（Home の実効値）が持ち、DB は掃除・出来事の見分け・読みのたびに今の値を読む。
struct AutomationRetention: Equatable {
  var runCount: Int
  var runDays: Int
  var eventDays: Int

  static let standard = AutomationRetention(runCount: 20, runDays: 7, eventDays: 30)
  static let runCountRange = 1...1000
  static let dayRange = 1...365
}

extension AutomationRetention {
  init(_ settings: EffectiveSettings) {
    self.init(
      runCount: settings[SettingKeys.automationRunRetentionCount],
      runDays: settings[SettingKeys.automationRunRetentionDays],
      eventDays: settings[SettingKeys.automationEventRetentionDays])
  }
}
