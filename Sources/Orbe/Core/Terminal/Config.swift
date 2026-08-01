import AppKit
import GhosttyKit

/// Orbe のキュレート既定 → user の ~/.config/ghostty の順で読み込んだ config を組み立てる。
/// 読み込み順が後勝ち（スカラ値は後の読み込みが上書き）なので、既定を先・user を後に読むと
/// user が Orbe 既定を上書きできる。
enum Config {
  static func load() -> ghostty_config_t {
    guard let cfg = ghostty_config_new() else { fatalError("ghostty_config_new failed") }
    // 1. Orbe 既定（バンドル Resources にのみ存在。dev 実行＝バンドル無しでは不在 → user 設定のみ）。
    if let path = Bundle.main.url(forResource: "orbe-defaults", withExtension: "conf")?.path {
      ghostty_config_load_file(cfg, path)
    }
    // 2. user の ~/.config/ghostty（後勝ちで上書き）。
    ghostty_config_load_default_files(cfg)
    // 3. 設定パレットの生成 conf（GUI が触ったキーだけ）。最後＝後勝ちで Orbe 既定・user の両方に勝つ。
    if let gui = GuiConfig.fileURL, FileManager.default.fileExists(atPath: gui.path) {
      ghostty_config_load_file(cfg, gui.path)
    }
    ghostty_config_finalize(cfg)
    return cfg
  }
}
