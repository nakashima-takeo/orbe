import Foundation
import OrbeSound

/// 設定項目の識別子。値の担体はスコープ非依存の `SettingsLayer`（SettingID→型付き値のマップ）で、
/// 解決・検証・永続・control 列挙は `SettingsRegistry` の descriptor 走査で駆動する。
/// 項目追加は descriptor を 1 件・typed key 定数を 1 行書くだけ（鏡像コードは無い）。
enum SettingID: CaseIterable {
  case fontSize, backgroundOpacity, backgroundBlur, cursorStyleBlink, theme,
    defaultAgent, fontFamily, tabTitleFontFamily, emojiFont, agentStateIcons,
    worktreeDir, notificationSound, notificationSoundVolume, notificationSoundEnabled,
    notificationSoundCustomDone, notificationSoundCustomWaiting,
    notificationSoundCustomWaitingSameAsDone, menuBarNoticeDwell
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
  static let worktreeDir = DefaultedSettingKey<String>(.worktreeDir)
  static let notificationSound = DefaultedSettingKey<AgentSoundChoice>(.notificationSound)
  static let notificationSoundVolume = DefaultedSettingKey<Int>(.notificationSoundVolume)
  static let notificationSoundEnabled = DefaultedSettingKey<Bool>(.notificationSoundEnabled)
  static let menuBarNoticeDwell = DefaultedSettingKey<Int>(.menuBarNoticeDwell)
  /// 「waiting でも done と同じ音を鳴らす」。key に `custom` を含むのは、custom 選択中にしか
  /// 効かないつまみだと公開 key（CLI/control/ディスク）が自ら語るため。
  static let notificationSoundCustomWaitingSameAsDone = DefaultedSettingKey<Bool>(
    .notificationSoundCustomWaitingSameAsDone)
  static let fontFamily = SettingKey<String>(.fontFamily)  // nil＝既定チェーンへ解決
  static let tabTitleFontFamily = SettingKey<String>(.tabTitleFontFamily)  // nil＝システム等幅 11pt
  static let defaultAgent = SettingKey<String>(.defaultAgent)  // nil＝検出先頭へ fallback
  // nil＝未取り込み（鳴らす段で紋章の同 event 音へフォールバックする）
  static let notificationSoundCustomDone = SettingKey<CustomSoundSource>(
    .notificationSoundCustomDone)
  static let notificationSoundCustomWaiting = SettingKey<CustomSoundSource>(
    .notificationSoundCustomWaiting)

  /// `sounds/` の実体を指す key の全体。**GC の契機判定と参照集合の収集がこの 1 つを読む**
  /// ——2 箇所に書き分けると、片方だけ足し忘れたときに GC が参照中のファイルを消す
  /// （しかも鳴る音は紋章へ黙って落ちるので、消えたことに気づけない）。
  static let customSoundSources = [notificationSoundCustomDone, notificationSoundCustomWaiting]
}
