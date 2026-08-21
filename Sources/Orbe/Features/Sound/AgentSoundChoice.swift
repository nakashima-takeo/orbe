import OrbeSound

/// 通知音として何を鳴らすかの**選択**（設定値）。12 案のどれか、または取り込んだカスタム音源。
///
/// `NotificationSound`（OrbeSound の純 DSP 語彙）へ `custom` を足さないのは、あちらが
/// 「合成定義を持つ案」の閉じた宇宙だから——合成定義を持たない case が混ざると
/// `SoundCatalog.program` の全 switch が壊れる。「どれを鳴らすか」はアプリ層の関心なので、
/// この enum がその 1 段上に立つ。
enum AgentSoundChoice: Equatable {
  case preset(NotificationSound)
  case custom

  /// 設定値・ディスク・CLI・control で共通の rawValue。案は案自身の rawValue をそのまま名乗り、
  /// カスタムだけがこの 1 語を占める（`NotificationSound` にこの名の案は無い）。
  static let customRawValue = "custom"

  /// 既定の選択（未設定時に鳴るもの）。案の既定は `NotificationSound.default` が SSOT。
  static let `default` = AgentSoundChoice.preset(.default)

  init?(rawValue: String) {
    if rawValue == Self.customRawValue {
      self = .custom
    } else if let sound = NotificationSound(rawValue: rawValue) {
      self = .preset(sound)
    } else {
      return nil
    }
  }

  var rawValue: String {
    switch self {
    case .preset(let sound): return sound.rawValue
    case .custom: return Self.customRawValue
    }
  }

  /// 設定パレット行・descriptor display の表示ラベル。案は案自身が名乗る（`NotificationSound+App`）。
  var labelKey: L10nKey {
    switch self {
    case .preset(let sound): return sound.labelKey
    case .custom: return .settingsNotificationSoundCustom
    }
  }

  /// 値域（descriptor の enumeration・control config_set の検証が読む）。
  static var allRawValues: [String] {
    NotificationSound.allCases.map(\.rawValue) + [customRawValue]
  }
}

extension AgentSoundChoice: SettingConvertible {
  init?(settingValue: SettingValue) {
    guard case .string(let raw) = settingValue, let choice = AgentSoundChoice(rawValue: raw) else {
      return nil
    }
    self = choice
  }
  var settingValue: SettingValue { .string(rawValue) }
}
