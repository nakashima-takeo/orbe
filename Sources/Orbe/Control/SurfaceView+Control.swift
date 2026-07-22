import Foundation
import GhosttyKit

/// 外部制御チャネルがペインへ作用する libghostty 経路。
/// すべて main スレッドで呼ぶ（libghostty surface API は main 規律）。
extension SurfaceView {
  /// `.app` 同梱の状態報告 binary（`<bundle>/Contents/Resources/bin/orbe-report`）の絶対パス。
  /// `swift run`（バンドル無し）では nil → env 未注入で hook が no-op。
  static var reportBinaryPath: String? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let path = resources.appendingPathComponent("bin/orbe-report").path
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
  }

  /// `.app` 同梱 CLI（`<bundle>/Contents/Resources/bin`。bare `orb` を含む）のディレクトリ。
  /// root ペインの PATH 先頭へ前置してペイン内から bare `orb` を解決させる。`swift run`（バンドル無し）
  /// では nil → PATH 注入なし。
  static var bundledBinDir: String? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let path = resources.appendingPathComponent("bin").path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
      return nil
    }
    return path
  }

  /// 同梱 CLI（bare `orb`）を全ペインで解決させるため bin/ を PATH 先頭へ前置する。既存 PATH
  /// （root agent タブは initialEnv の login PATH・root その他と split は本プロセスの PATH）を保持して
  /// 前置だけ行う（login シェルの path_helper 越しでも bin/ が残る）。split は libghostty の
  /// inherited_config が bin/ 入り PATH を運ばないため split でも呼ぶ（呼ばないと split で `orb` が
  /// not found）。バンドル無し（swift run）では no-op。
  static func prependBundledBin(to env: inout [String: String]) {
    guard let binDir = bundledBinDir else { return }
    let base = env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
    env["PATH"] = base.isEmpty ? binDir : "\(binDir):\(base)"
  }

  /// 画面テキストを平文で読む。`scrollback` 真ならスクロールバック全体、偽なら可視範囲のみ。
  func controlReadText(scrollback: Bool) -> String? {
    guard let surface = surfacePtr else { return nil }
    let tag = scrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
    let sel = ghostty_selection_s(
      top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
      bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
      rectangle: false)
    var out = ghostty_text_s()
    guard ghostty_surface_read_text(surface, sel, &out) else { return nil }
    defer { ghostty_surface_free_text(surface, &out) }
    guard let ptr = out.text, out.text_len > 0 else { return "" }
    return String(
      bytes: UnsafeRawBufferPointer(start: ptr, count: Int(out.text_len)), encoding: .utf8) ?? ""
  }

  /// テキストをペーストと同様に PTY へ書く。
  func controlSendText(_ text: String) {
    guard let surface = surfacePtr else { return }
    text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
  }

  /// 解決済みのキーをペインへ送る（PTY バイト or keycode press/release）。
  func controlSendKey(_ key: ControlKey) {
    guard let surface = surfacePtr else { return }
    switch key {
    case .text(let s):
      controlSendText(s)
    case .special(let keycode, let mods):
      for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
        var k = ghostty_input_key_s()
        k.action = action
        k.mods = mods
        k.consumed_mods = ghostty_input_mods_e(rawValue: 0)
        k.keycode = keycode
        k.text = nil
        k.unshifted_codepoint = 0
        k.composing = false
        _ = ghostty_surface_key(surface, k)
      }
    }
  }
}
