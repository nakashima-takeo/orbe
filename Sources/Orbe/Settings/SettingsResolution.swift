import Foundation

/// 設定の解決チェーン（WS 上書き → global → 既定値）を担う型群。
/// global 層に workspace 上書き層を重ねた `EffectiveSettings` が読み口の 1 箇所で、
/// `GuiConfig.regenerate` / `syncWindowOpacity` / `applyActiveWorkspaceConfig` が共有する。

/// 設定の編集スコープ。global＝settings.json（全 workspace 既定）、workspace＝アクティブ workspace の上書き。
enum SettingsScope { case global, workspace }

/// 単一代入（値 or nil＝解除して継承へ）。全項目対応。パレットは typed init、control は key+JSON init で組む。
struct SettingChange: Equatable {
  let id: SettingID
  /// nil＝この項目の上書きを除去（継承へ戻す）。非 nil＝その値を書く。
  let value: SettingValue?

  init(id: SettingID, value: SettingValue?) {
    self.id = id
    self.value = value
  }

  /// unset 意味を持つ key の typed 構築（nil で解除）。
  init<V>(_ key: SettingKey<V>, _ v: V?) {
    id = key.id
    value = v?.settingValue
  }

  /// 既定つき key の typed 構築（nil で解除）。
  init<V>(_ key: DefaultedSettingKey<V>, _ v: V?) {
    id = key.id
    value = v?.settingValue
  }

  /// control 用: canonical key ＋ JSON 値から組む。値域は registry の domain で検証する（唯一の検証点）。
  /// JSON null は「解除（継承へ）」として受理。未知 key・型不一致・値域外は nil（呼び出し側で -32602）。
  init?(key: String, jsonValue: Any) {
    guard let d = SettingsRegistry.all.first(where: { $0.key == key }) else { return nil }
    if jsonValue is NSNull {
      self.init(id: d.id, value: nil)
      return
    }
    guard let v = d.domain.validate(jsonValue) else { return nil }
    self.init(id: d.id, value: v)
  }
}

/// 実効設定＝`global.overlaid(with: override)` の読み口。解決チェーンはここ 1 箇所。
struct EffectiveSettings {
  /// 重ね済みの層（global に WS 上書きを被せたもの）。gui.conf は raw（未設定は行を出さない）でここを読む。
  let layer: SettingsLayer

  init(_ layer: SettingsLayer) { self.layer = layer }

  /// 明示値のみ（nil＝未設定の意味論）。
  subscript<V>(key: SettingKey<V>) -> V? { layer[key] }

  /// 明示値 ?? 既定（non-nil）。既定は descriptor の `defaultValue` が SSOT。
  subscript<V>(key: DefaultedSettingKey<V>) -> V {
    if let v = layer[key] { return v }
    guard let dv = SettingsRegistry.descriptor(key.id).defaultValue(),
      let v = V(settingValue: dv)
    else {
      preconditionFailure(
        "DefaultedSettingKey \(key.id) has no default value (registry invariant violated)")
    }
    return v
  }

  /// 型消去のまま 1 項目を読む（control の generic 経路）。未設定は nil。
  func value(_ id: SettingID) -> SettingValue? { layer.value(id) }
}
