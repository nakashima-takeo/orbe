import Foundation

/// 設定値の閉じた宇宙。型消去は layer 内部だけに閉じ、表面は `SettingKey<V>`/`DefaultedSettingKey<V>` で
/// 型付けする（この enum を直に触るのは control の generic 経路・永続 codec・descriptor の display/guiConf のみ）。
enum SettingValue: Equatable {
  case int(Int)
  case bool(Bool)
  case string(String)
  case stringMap([String: String])
}

/// `SettingValue` と相互変換できる設定値型（typed 表面と型消去 layer の橋）。
/// 変換規則はこの 1 箇所に閉じ、`SettingsLayer`/`EffectiveSettings`/`SettingChange` の typed 経路が共有する。
protocol SettingConvertible {
  init?(settingValue: SettingValue)
  var settingValue: SettingValue { get }
}

extension Int: SettingConvertible {
  init?(settingValue: SettingValue) {
    guard case .int(let v) = settingValue else { return nil }
    self = v
  }
  var settingValue: SettingValue { .int(self) }
}

extension Bool: SettingConvertible {
  init?(settingValue: SettingValue) {
    guard case .bool(let v) = settingValue else { return nil }
    self = v
  }
  var settingValue: SettingValue { .bool(self) }
}

extension String: SettingConvertible {
  init?(settingValue: SettingValue) {
    guard case .string(let v) = settingValue else { return nil }
    self = v
  }
  var settingValue: SettingValue { .string(self) }
}

extension ThemeMode: SettingConvertible {
  init?(settingValue: SettingValue) {
    guard case .string(let raw) = settingValue, let mode = ThemeMode(rawValue: raw) else {
      return nil
    }
    self = mode
  }
  var settingValue: SettingValue { .string(rawValue) }
}

extension Dictionary: SettingConvertible where Key == String, Value == String {
  init?(settingValue: SettingValue) {
    guard case .stringMap(let m) = settingValue else { return nil }
    self = m
  }
  var settingValue: SettingValue { .stringMap(self) }
}
