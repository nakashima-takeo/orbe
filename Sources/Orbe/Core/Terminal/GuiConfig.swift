import Foundation

/// 設定パレット（ドメインA）が触ったキーを sparse に書き出す生成 conf
/// （theme 行は定数・emoji-font 行は実効値で常時 emit）。
/// `Config.load()` が user の `~/.config/ghostty` の後（後勝ち）に読み込む。
/// user 資産は一切書き換えず、GUI が握るキーだけをこの別ファイルに分離する。
/// 置き場は settings.json と同居（`StateDir.base()/gui.conf`、ORBE_STATE_DIR を honor）。
enum GuiConfig {
  /// テスト用に保存先を差し替える（settings.json と同じ seam）。本番は nil。
  static var fileURLOverride: URL?

  static var fileURL: URL? {
    if let override = fileURLOverride { return override }
    return StateDir.base()?.appendingPathComponent("gui.conf")
  }

  /// 実効設定の raw な各キーだけを行として組み立て atomic 書き込みする。
  /// 行と順序は `SettingsRegistry.all`（正準順）の各 descriptor の `guiConf` が宣言する（gui.conf 非経由の
  /// 項目は `guiConf==nil` で skip）。theme 行（値非依存の定数・ユーザー conf の theme 指定を層3後勝ちで
  /// 無効化）と emoji-font 行（実効値で map 先が変わる font-codepoint-map・単一出所）は常時 emit される
  /// ため gui.conf は空にならない。
  static func regenerate(from settings: EffectiveSettings) {
    guard let url = fileURL else { return }
    let lines = SettingsRegistry.all.compactMap { $0.guiConf?(settings) }
    let text = lines.joined(separator: "\n") + "\n"
    try? Data(text.utf8).write(to: url, options: .atomic)
  }
}
