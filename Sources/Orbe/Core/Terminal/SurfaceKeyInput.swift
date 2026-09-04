import GhosttyKit

/// 物理キー経路と制御チャネルが同じ形で surface へ渡すキー入力（`ghostty_input_key_s` から、送出のたびに
/// 決まる action / composing を除いたもの）。符号化（legacy / kitty keyboard protocol / application cursor
/// 等）は libghostty が端末モードに応じて行う。
struct SurfaceKeyInput: Equatable {
  /// keycodes.zig の mac 列に無い値。libghostty が `Key.unidentified` に落とし、`text` /
  /// `unshiftedCodepoint` から符号化する。0xFFFF は mac 列に実在する（mac に無いキーの穴埋め値）ので使わない。
  static let noKeycode: UInt32 = .max

  let keycode: UInt32
  /// 生成文字。C0 制御文字と DEL は `key.text` に載らず keycode から符号化される（`textCarriesToKey`）。
  let text: String?
  /// 無修飾文字（無ければ 0）。
  let unshiftedCodepoint: UInt32
  let mods: ghostty_input_mods_e
  /// `text` を生成するために消費された修飾。libghostty は `mods` − `consumedMods`（effective mods）を
  /// 符号化の分岐判定に使う——無修飾扱いになると素の Enter/Tab/Backspace・テキスト直送へ落ち、
  /// alt の ESC 前置も消える。CSI に載る修飾値そのものは生 `mods` から作られる。`key.text` に
  /// 載らない入力では参照されない。cf. vendor/ghostty src/input/key.zig（effectiveMods）
  let consumedMods: ghostty_input_mods_e

  /// text を `key.text` に載せてよいか。C0 制御文字（先頭 UTF-8 バイト < 0x20）と DEL（0x7F）は載せず
  /// keycode のみで送り、符号化を libghostty に委ねる。判定集合は libghostty の `isControl`（C0 と DEL）と
  /// 同一。cf. vendor/ghostty src/input/key_encode.zig（isControl）
  /// 載せると effectiveMods が consumed_mods を差し引き、Shift+Backspace の修飾が潰れる。
  /// 翻訳（`ghostty_surface_key_translation_mods`）が alt を落とさない構成では consumed に alt が残るので、
  /// Alt+Enter / Option+Backspace も同じ潰れ方をする
  /// （`true` の翻訳は alt を無条件に落とすので consumed に alt が入らない）。
  /// scalar でなくバイトで判定するのでマルチバイト UTF-8 は常に載る。
  static func textCarriesToKey(_ text: String) -> Bool {
    guard let first = text.utf8.first else { return false }
    return first >= 0x20 && first != 0x7F
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
