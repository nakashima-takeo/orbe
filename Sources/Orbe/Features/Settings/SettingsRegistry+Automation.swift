import Foundation

/// 自動化の保持（`AutomationRetention`）の設定。自動化は workspace に属さず、Home の実効値だけが効く。
extension SettingsRegistry {
  static let automationRetention: [SettingDescriptor] = [
    SettingDescriptor(
      id: .automationRunRetentionCount, key: "automation-run-retention-count",
      labelKey: .settingsAutomationRunRetentionCount, activation: .stepper,
      defaultValue: { .int(AutomationRetention.standard.runCount) },
      domain: .intRange(AutomationRetention.runCountRange, step: 1, unit: "runs"),
      guiConf: nil,  // gui.conf 非経由
      display: countLabel(one: .settingsRunsValueOne, other: .settingsRunsValueOther),
      unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .automationRunRetentionDays, key: "automation-run-retention-days",
      labelKey: .settingsAutomationRunRetentionDays, activation: .stepper,
      defaultValue: { .int(AutomationRetention.standard.runDays) },
      domain: .intRange(AutomationRetention.dayRange, step: 1, unit: "days"),
      guiConf: nil,  // gui.conf 非経由
      display: countLabel(one: .settingsDaysValueOne, other: .settingsDaysValueOther),
      unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .automationEventRetentionDays, key: "automation-event-retention-days",
      labelKey: .settingsAutomationEventRetentionDays, activation: .stepper,
      defaultValue: { .int(AutomationRetention.standard.eventDays) },
      domain: .intRange(AutomationRetention.dayRange, step: 1, unit: "days"),
      guiConf: nil,  // gui.conf 非経由
      display: countLabel(one: .settingsDaysValueOne, other: .settingsDaysValueOther),
      unsetPlaceholderKey: nil),
  ]

  /// 数に単位を付けた値表示（回数「20回」・日数「7日」）。書式と単数・複数は L10n が持つ。
  private static func countLabel(one: L10nKey, other: L10nKey)
    -> (SettingValue, LocalizationStore) -> String
  {
    { v, store in if case .int(let n) = v { store.plural(n, one: one, other: other) } else { "" } }
  }
}
