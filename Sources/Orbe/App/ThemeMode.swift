import AppKit

/// テーマ設定（外観スイッチ）。Auto/Dark/Light の3値で、アプリ全体（chrome＋ターミナル）の
/// ライト/ダークを `NSApp.appearance` で決める（`WindowController.applyActiveWorkspaceConfig`）。
/// chrome は動的トークン（`DesignTokens` の appearance プロバイダ）、ターミナルは既存配線
/// （`SurfaceView.viewDidChangeEffectiveAppearance` → `ghostty_surface_set_color_scheme` →
/// soft RELOAD_CONFIG）が appearance 変化へ追従するため、この enum が唯一のスイッチになる。
enum ThemeMode: String, Codable, Equatable {
  case auto, dark, light

  /// 寛容デコード: 旧 settings.json / workspaces.json に残る任意テーマ名（"Dracula" 等）は `.auto` へ
  /// 丸める。ここで throw すると load がファイル全体を nil にし全設定を失うため必須。
  /// 次回保存で丸めた rawValue が書かれ、旧値は自然に消える。
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
