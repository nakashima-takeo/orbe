import Carbon.HIToolbox
import GhosttyKit

/// 制御チャネルの宛先 ID 発番（プロセス内で単調増加・型をまたいで一意）。
/// workspace / tab(TerminalController) / pane(SurfaceView) すべてが同じ空間から引く。
/// main スレッド規律下でのみ呼ばれる（全オブジェクト生成は main）。
enum IdGen {
  nonisolated(unsafe) private static var counter = 0
  static func next() -> Int {
    counter += 1
    return counter
  }
  /// カウンタを少なくとも `value` まで前進させる。復元カードの id（前回 run の値）と、以後
  /// 新規採番される pane/card の id の衝突を避けるため load 時に呼ぶ。
  static func bump(atLeast value: Int) {
    if counter < value { counter = value }
  }
}

/// 外部 → Orbe の制御で起きた出来事。`wait_for_event` がフィルタして待つ。
/// 生の PTY 出力は libghostty が host に出さないため、扱えるのは whitelist された
/// OSC 由来シグナル（agent 状態・タイトル・cwd）とペインのライフサイクルに限る。
struct ControlEvent {
  /// `wait_for_event` が受け付ける kind の全体。フィルタの語彙はここが唯一の出所で、
  /// 未知の語は `registerWait` が待機を張る前に -32602 で弾く（黙って時間切れにしない）。
  static let kinds: Set<String> = ["agent_state", "pane_title", "pwd", "pane_closed"]

  /// イベント種別。取り得る値は `kinds`。
  let kind: String
  let paneId: Int
  /// kind 固有の値（agent_state なら状態語、pane_title ならタイトル、pwd なら path）。
  let value: String?

  func toDict() -> [String: Any] {
    var d: [String: Any] = ["kind": kind, "paneId": paneId]
    if let value { d["value"] = value }
    return d
  }
}

/// キー名（"enter" / "ctrl+c" / "shift+a" 等）を、物理キー経路と同じ `SurfaceKeyInput` へ解決する。
/// 名前付きキーは実 keycode、単一文字は keycode 無し（libghostty が生成文字・無修飾文字から符号化する）。
enum ControlKey {
  /// 名前付きキーの行。`text` / `unshiftedCodepoint` は keycode だけでは符号化されないキーが持つ
  /// （space は PC-style 関数キー表にも kitty 表にも無く、text が無いと何も書かれない）。
  struct NamedKey {
    let keycode: UInt32
    let text: String?
    let unshiftedCodepoint: UInt32

    init(_ keycode: Int, text: String? = nil, unshiftedCodepoint: UInt32 = 0) {
      self.keycode = UInt32(keycode)
      self.text = text
      self.unshiftedCodepoint = unshiftedCodepoint
    }
  }

  /// 名前付きキーの全体。`orb pane --help` の `KEYS:` 行はここの写しで、ドリフトは
  /// `testPaneHelpListsEveryKeyName` が突き合わせて落とす（`KINDS:` / `KEYS:` と同じ守り方）。
  static let namedKeys: [String: NamedKey] = [
    "enter": NamedKey(kVK_Return), "return": NamedKey(kVK_Return),
    "tab": NamedKey(kVK_Tab),
    "escape": NamedKey(kVK_Escape), "esc": NamedKey(kVK_Escape),
    "space": NamedKey(kVK_Space, text: " ", unshiftedCodepoint: 0x20),
    "backspace": NamedKey(kVK_Delete), "delete": NamedKey(kVK_ForwardDelete),
    "up": NamedKey(kVK_UpArrow), "down": NamedKey(kVK_DownArrow),
    "left": NamedKey(kVK_LeftArrow), "right": NamedKey(kVK_RightArrow),
    "home": NamedKey(kVK_Home), "end": NamedKey(kVK_End),
    "pageup": NamedKey(kVK_PageUp), "pagedown": NamedKey(kVK_PageDown),
  ]

  private static let modTokens: [String: ghostty_input_mods_e] = [
    "ctrl": GHOSTTY_MODS_CTRL, "control": GHOSTTY_MODS_CTRL,
    "alt": GHOSTTY_MODS_ALT, "opt": GHOSTTY_MODS_ALT, "option": GHOSTTY_MODS_ALT,
    "meta": GHOSTTY_MODS_ALT,
    "shift": GHOSTTY_MODS_SHIFT,
    "cmd": GHOSTTY_MODS_SUPER, "super": GHOSTTY_MODS_SUPER,
  ]

  /// spec 全体を lowercased で読む（キー名・修飾・単一文字とも case-insensitive。大文字は `shift+a`）。
  /// 単一文字は Unicode scalar ちょうど 1 つで制御文字でないもの。複数 scalar の grapheme は無修飾文字を
  /// 持てず libghostty が修飾を黙殺する、制御文字は `key.text` に載らない——どちらも `send_text` の領分。
  /// `cmd`/`super` 付き単一文字は端末へ届く形が無いので拒否し、修飾を黙殺して素の文字を注入しない。
  static func parse(_ spec: String) -> SurfaceKeyInput? {
    let parts = spec.lowercased().split(separator: "+").map(String.init)
    guard let base = parts.last, !base.isEmpty else { return nil }
    var mods: UInt32 = 0
    for token in parts.dropLast() {
      guard let m = modTokens[token] else { return nil }
      mods |= m.rawValue
    }

    if let named = namedKeys[base] {
      return SurfaceKeyInput(
        keycode: named.keycode, text: named.text, unshiftedCodepoint: named.unshiftedCodepoint,
        mods: ghostty_input_mods_e(rawValue: mods), consumedMods: ghostty_input_mods_e(rawValue: 0))
    }

    guard base.unicodeScalars.count == 1, let scalar = base.unicodeScalars.first,
      SurfaceKeyInput.textCarriesToKey(base),
      mods & GHOSTTY_MODS_SUPER.rawValue == 0
    else { return nil }
    // shift は大文字化が実際に起きたときだけ消費する。大文字化しない文字（`shift+1` 等）はレイアウト
    // 不明で `!` を作れないので、shift を修飾として残しアプリ側へ伝える（消費扱いにすると kitty で
    // shift が消えて黙って `1` になる）。
    var text = base
    var consumed: UInt32 = 0
    if mods & GHOSTTY_MODS_SHIFT.rawValue != 0 {
      let upper = base.uppercased()
      if upper.unicodeScalars.count == 1, upper != base {
        text = upper
        consumed = GHOSTTY_MODS_SHIFT.rawValue
      }
    }
    return SurfaceKeyInput(
      keycode: SurfaceKeyInput.noKeycode, text: text, unshiftedCodepoint: scalar.value,
      mods: ghostty_input_mods_e(rawValue: mods),
      consumedMods: ghostty_input_mods_e(rawValue: consumed))
  }
}
