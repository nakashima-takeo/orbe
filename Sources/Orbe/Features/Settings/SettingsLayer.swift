import Foundation

/// スコープ非依存の均一レイヤ（SettingID→型付き値のマップ）。global 層も workspace 上書き層もこの 1 型で、
/// 「重ねる・照会する・1 項目書く・1 項目消す」が全項目に対し generic に成立する。
/// 型消去（`SettingValue`）はこの内部に閉じ、表面は `SettingKey<V>`/`DefaultedSettingKey<V>` で型付けする。
///
/// ディスク表現は canonical key（kebab）の値マップ（`SettingsRegistry` の key/domain を SSOT に codec する）。
struct SettingsLayer: Equatable {
  private var values: [SettingID: SettingValue]

  init(_ values: [SettingID: SettingValue] = [:]) { self.values = values }

  /// typed 読み書き（未設定/解除は nil）。unset が意味を持つ項目用。
  subscript<V>(key: SettingKey<V>) -> V? {
    get { values[key.id].flatMap(V.init(settingValue:)) }
    set { values[key.id] = newValue?.settingValue }
  }

  /// typed 読み書き（layer 上は raw = 未設定は nil）。既定への解決は `EffectiveSettings` が担う。
  subscript<V>(key: DefaultedSettingKey<V>) -> V? {
    get { values[key.id].flatMap(V.init(settingValue:)) }
    set { values[key.id] = newValue?.settingValue }
  }

  /// 型消去のまま 1 項目を読む（control の generic 経路・表示が使う）。未設定は nil。
  func value(_ id: SettingID) -> SettingValue? { values[id] }

  /// 単一代入（値 or nil＝解除して継承へ）。書き＝1 実装。
  mutating func apply(_ change: SettingChange) { values[change.id] = change.value }

  /// この層に override 層を重ねる（override の非 nil 項目が勝つ）。重ね＝1 実装。
  func overlaid(with override: SettingsLayer) -> SettingsLayer {
    var out = values
    for (id, v) in override.values { out[id] = v }
    return SettingsLayer(out)
  }

  /// 1 項目も持たないか（空上書きの nil 畳み込みに使う）。
  var isEmpty: Bool { values.isEmpty }
}

extension SettingsLayer: Codable {
  private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(_ s: String) { stringValue = s }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: DynamicKey.self)
    for descriptor in SettingsRegistry.all {
      guard let v = values[descriptor.id] else { continue }
      let key = DynamicKey(descriptor.key)
      switch v {
      case .int(let n): try c.encode(n, forKey: key)
      case .bool(let b): try c.encode(b, forKey: key)
      case .string(let s): try c.encode(s, forKey: key)
      case .stringMap(let m): try c.encode(m, forKey: key)
      }
    }
  }

  init(from decoder: Decoder) throws {
    self = try Self.decode(from: decoder, strictUnknownKeys: false)
  }

  /// canonical key マップから読む。`strictUnknownKeys` が true なら未知 key で throw（旧形式判定に使う）、
  /// false なら未知 key を無視する。値の型は registry の domain を SSOT に決める。
  static func decode(from decoder: Decoder, strictUnknownKeys: Bool) throws -> SettingsLayer {
    let c = try decoder.container(keyedBy: DynamicKey.self)
    var out: [SettingID: SettingValue] = [:]
    for key in c.allKeys {
      guard let descriptor = SettingsRegistry.all.first(where: { $0.key == key.stringValue })
      else {
        if strictUnknownKeys {
          throw DecodingError.dataCorruptedError(
            forKey: key, in: c, debugDescription: "unknown setting key: \(key.stringValue)")
        }
        continue
      }
      if strictUnknownKeys {
        out[descriptor.id] = try descriptor.domain.decodeValue(from: c, forKey: key)
      } else if let v = try? descriptor.domain.decodeValue(from: c, forKey: key) {
        // 非 strict（settings.json v1）: 読めない既知キー（型不一致）は未知キー同様 skip し他項目を活かす。
        // 1 項目の型不一致で層全体を失って legacy 空移行の破壊 save に落ちるのを防ぐ。
        out[descriptor.id] = v
      }
    }
    return SettingsLayer(out)
  }
}
