import Foundation
import GhosttyKit

/// 外部制御チャネルが surface へ作用する libghostty 経路。
/// すべて main スレッドで呼ぶ（libghostty surface API は main 規律）。
extension SurfaceView {
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

  /// 解決済みのキー入力を surface へ press / release の 1 打として送る。
  func controlSendKey(_ input: SurfaceKeyInput) {
    for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
      sendKeyInput(input, action: action, composing: false)
    }
  }
}
