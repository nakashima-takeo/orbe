import AppKit

/// テーマ設定（外観スイッチ）。Auto/Dark/Light の3値で、アプリ全体（chrome＋ターミナル）の
/// ライト/ダークを `NSApp.appearance` で決める（`WindowController.applyActiveWorkspaceConfig`）。
/// chrome は動的トークン（`DesignTokens` の appearance プロバイダ）、ターミナルは既存配線
/// （`SurfaceView.viewDidChangeEffectiveAppearance` → `ghostty_surface_set_color_scheme` →
/// soft RELOAD_CONFIG）が appearance 変化へ追従するため、この enum が唯一のスイッチになる。
enum ThemeMode: String, Codable, Equatable {
  case auto, dark, light

  /// 寛容デコード: 値域外の rawValue は `.auto` として読む。この型を field に持つのは旧形式の移行
  /// struct（`LegacySettingsFile`・`LegacyWorkspaceSettingsOverride`）だけで、そこで throw すると
  /// struct ごと decode が落ちる——`theme` 1 項目の異常で移行元の設定を全部失わないため。
  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = ThemeMode(rawValue: raw) ?? .auto
  }

  /// `NSApp.appearance` へ渡す外観（auto は nil＝OS の外観設定へ追従）。
  var appearance: NSAppearance? {
    switch self {
    case .auto: return nil
    case .dark: return NSAppearance(named: .darkAqua)
    case .light: return NSAppearance(named: .aqua)
    }
  }

  /// 表示ラベル（design 見本 Settings 画面の Seg 表記そのまま）。
  var label: String {
    switch self {
    case .auto: return "Auto"
    case .dark: return "Dark"
    case .light: return "Light"
    }
  }
}
