import Foundation

/// 開発ビルドか（未設定時の「開発中の機能を有効化」default を決める SSOT）。`build-app.sh` が既定で焼く
/// `-DORBE_DEV` で true、公開リリース（`release-app.sh` は ORBE_CHANNEL=release でフラグ抑止）で false。
/// `#if ORBE_DEV` はこの 1 箇所だけに閉じる。`#if DEBUG` は両ビルドとも -c release で焼くため使えない。
let isDevBuild: Bool = {
  #if ORBE_DEV
    return true
  #else
    return false
  #endif
}()

/// 設定項目の識別子。値の担体はスコープ非依存の `SettingsLayer`（SettingID→型付き値のマップ）で、
/// 解決・検証・永続・control 列挙は `SettingsRegistry` の descriptor 走査で駆動する。
/// 項目追加は descriptor を 1 件・typed key 定数を 1 行書くだけ（鏡像コードは無い）。
enum SettingID: CaseIterable {
  case fontSize, backgroundOpacity, backgroundBlur, cursorStyleBlink, theme,
    defaultAgent, fontFamily, tabTitleFontFamily, emojiFont, agentStateIcons, devFeaturesEnabled
}

/// unset が固有の意味を持つ項目（fontFamily＝既定チェーン・defaultAgent＝検出先頭）の phantom-typed key。
/// 読みは `EffectiveSettings[key] -> V?`（nil＝未設定の意味論）。
struct SettingKey<V: SettingConvertible> {
  let id: SettingID
  init(_ id: SettingID) { self.id = id }
}

/// 常に値が定まる項目（fontSize 等）の phantom-typed key。既定は descriptor の `defaultValue` が SSOT。
/// 読みは `EffectiveSettings[key] -> V`（明示値 ?? 既定・non-nil）。
struct DefaultedSettingKey<V: SettingConvertible> {
  let id: SettingID
  init(_ id: SettingID) { self.id = id }
}

/// 項目ごとの typed 宣言（1 項目 1 行）。読み書きの表面はこの key を通し、型消去は `SettingsLayer` 内部に閉じる。
enum SettingKeys {
  static let fontSize = DefaultedSettingKey<Int>(.fontSize)
  static let backgroundOpacity = DefaultedSettingKey<Int>(.backgroundOpacity)
  static let backgroundBlur = DefaultedSettingKey<Bool>(.backgroundBlur)
  static let cursorStyleBlink = DefaultedSettingKey<Bool>(.cursorStyleBlink)
  static let theme = DefaultedSettingKey<ThemeMode>(.theme)
  static let emojiFont = DefaultedSettingKey<EmojiFontMode>(.emojiFont)
  static let agentStateIcons = DefaultedSettingKey<[String: String]>(.agentStateIcons)
  static let devFeaturesEnabled = DefaultedSettingKey<Bool>(.devFeaturesEnabled)
  static let fontFamily = SettingKey<String>(.fontFamily)  // nil＝既定チェーンへ解決
  static let tabTitleFontFamily = SettingKey<String>(.tabTitleFontFamily)  // nil＝システム等幅 11pt
  static let defaultAgent = SettingKey<String>(.defaultAgent)  // nil＝検出先頭へ fallback
}
