import Foundation

/// Orbe 固有設定のディスク永続（自前 JSON）。新形式 v1（version＋canonical key の値マップ）で読み書きし、
/// 旧形式（camelCase struct＋アプリ状態同居）からは無損失で自動移行する。
/// 保存先は workspaces.json と並ぶ `StateDir.base()/settings.json`。

/// settings.json 新形式（v1）。canonical key（kebab）の値マップを `SettingsLayer` として持つ。
private struct SettingsFileV1: Codable {
  var version: Int
  var values: SettingsLayer
}

/// version エンベロープの有無だけを見る軽量プローブ。新形式（version あり）か旧形式（無し）かの判定に使う。
private struct VersionProbe: Codable {
  var version: Int?
}

/// 旧 settings.json の形（camelCase・設定とアプリ状態が同居）。移行 decode 専用（将来消せる）。
/// 全 field Optional で寛容に読み、設定 9 項目は `SettingsLayer` へ・アプリ状態 3 項目は `AppStateFile` へ分ける。
private struct LegacySettingsFile: Codable {
  var defaultAgent: String?
  var agentPluginsInstalled: Bool?
  var completionInstalled: Bool?
  var cachedShellPath: String?
  var fontSize: Int?
  var theme: ThemeMode?
  var fontFamily: String?
  var backgroundOpacity: Int?
  var backgroundBlur: Bool?
  var cursorStyleBlink: Bool?
  var agentStateIcons: [String: String]?
  var devFeaturesEnabled: Bool?

  /// 設定 9 項目を新形式レイヤへ。nil は書かない（未設定＝レイヤに載せない）。
  func toLayer() -> SettingsLayer {
    var layer = SettingsLayer()
    layer[SettingKeys.fontSize] = fontSize
    layer[SettingKeys.backgroundOpacity] = backgroundOpacity
    layer[SettingKeys.backgroundBlur] = backgroundBlur
    layer[SettingKeys.cursorStyleBlink] = cursorStyleBlink
    layer[SettingKeys.theme] = theme
    layer[SettingKeys.fontFamily] = fontFamily
    layer[SettingKeys.defaultAgent] = defaultAgent
    layer[SettingKeys.devFeaturesEnabled] = devFeaturesEnabled
    layer[SettingKeys.agentStateIcons] = agentStateIcons
    return layer
  }

  /// アプリ状態 3 項目を app-state.json の形へ。
  func toAppState() -> AppStateFile {
    AppStateFile(
      agentPluginsInstalled: agentPluginsInstalled, completionInstalled: completionInstalled,
      cachedShellPath: cachedShellPath)
  }
}

enum SettingsPersistence {
  /// テスト用に保存先を差し替える（設定時はこちらを使う）。本番は nil。
  static var fileURLOverride: URL?

  static var fileURL: URL? {
    if let override = fileURLOverride { return override }
    return StateDir.base()?.appendingPathComponent("settings.json")
  }

  /// global 層を読む。`version` エンベロープの有無で新形式/旧形式を判別する。
  /// - 新形式（version あり）: `SettingsFileV1` として読む。読めた項目だけ返し、**破壊的な旧移行 save には
  ///   絶対に落とさない**（1 項目の型不一致・構造破損で settings.json 全体を空に上書きしない）。
  /// - 旧形式（version 無し）: 全体 decode 成功時のみ無損失移行（設定→v1・アプリ状態→app-state.json）。
  ///   移行は all-or-nothing（部分読みで残りを消さない）。app-state を先に書いてから settings.json を
  ///   新形式へ置換する（中間クラッシュでも settings.json が旧形式のまま残り次回再移行で完全回復）。
  /// - どちらでもない（欠落・非オブジェクト破損）は空層（現行挙動どおり既定へ fallback。上書きしない）。
  static func loadGlobal() -> SettingsLayer {
    guard let url = fileURL, let data = try? Data(contentsOf: url) else { return SettingsLayer() }
    if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data), probe.version != nil {
      return (try? JSONDecoder().decode(SettingsFileV1.self, from: data))?.values ?? SettingsLayer()
    }
    guard let legacy = try? JSONDecoder().decode(LegacySettingsFile.self, from: data) else {
      return SettingsLayer()
    }
    let layer = legacy.toLayer()
    AppStatePersistence.save(legacy.toAppState())  // 先に分離先へ退避（喪失窓を作らない）
    saveGlobal(layer)  // settings.json を新形式へ置き換え（アプリ状態 field は落ちる）
    return layer
  }

  /// global 層を新形式で書く（version:1＋canonical key マップ・`.sortedKeys` で安定）。
  static func saveGlobal(_ layer: SettingsLayer) {
    guard let url = fileURL else { return }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(SettingsFileV1(version: 1, values: layer)) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
