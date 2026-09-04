import GhosttyKit

/// 物理キー経路と制御チャネルが同じ形で surface へ渡すキー入力（`ghostty_input_key_s` から、送出のたびに
/// 決まる action / composing を除いたもの）。符号化（legacy / kitty keyboard protocol / application cursor
/// 等）は libghostty が端末モードに応じて行う。
struct SurfaceKeyInput: Equatable {
  /// keycodes.zig の mac 列に無い値。libghostty が `Key.unidentified` に落とし、`text` /
  /// `unshiftedCodepoint` から符号化する。0xFFFF は mac 列に実在する（mac に無いキーの穴埋め値）ので使わない。
  static let noKeycode: UInt32 = .max

  let keycode: UInt32
  /// 生成文字。制御文字（先頭 UTF-8 バイト < 0x20）は `key.text` に載らず keycode から符号化される。
  let text: String?
  /// 無修飾文字（無ければ 0）。
  let unshiftedCodepoint: UInt32
  let mods: ghostty_input_mods_e
  /// text 生成に消費された修飾。翻訳 mods から control / command を除いた集合。
  let consumedMods: ghostty_input_mods_e

  /// text を `key.text` に載せてよいか。制御文字（先頭 UTF-8 バイト < 0x20）は載せず keycode のみで
  /// 送り、符号化を libghostty に委ねる（載せると effectiveMods が「text 有り」分岐で consumed_mods を
  /// 差し引き Alt+Enter が潰れる）。scalar でなくバイトで判定するのでマルチバイト UTF-8 は常に載る。
  static func textCarriesToKey(_ text: String) -> Bool {
    guard let first = text.utf8.first else { return false }
    return first >= 0x20
  }
}

extension SurfaceView {
  /// キー入力を surface へ送る唯一の出口。text ポインタは libghostty が同期で消費するので
  /// `withCString` のスコープで足りる。
  func sendKeyInput(_ input: SurfaceKeyInput, action: ghostty_input_action_e, composing: Bool) {
    guard let surface = surfacePtr else { return }
    var key = ghostty_input_key_s()
    key.action = action
    key.mods = input.mods
    key.consumed_mods = input.consumedMods
    key.keycode = input.keycode
    key.unshifted_codepoint = input.unshiftedCodepoint
    key.composing = composing
    if let text = input.text, SurfaceKeyInput.textCarriesToKey(text) {
      text.withCString { tptr in
        key.text = tptr
        _ = ghostty_surface_key(surface, key)
      }
    } else {
      key.text = nil
      _ = ghostty_surface_key(surface, key)
    }
  }
}
