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
  /// `agent_state` / `pane_title` / `pwd` / `pane_closed`
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

/// キー名（"enter" / "ctrl+c" / "up" 等）を libghostty への送出形へ解決する。
/// - `.text`: PTY へ書くバイト列（印字文字・制御バイト。端末モード非依存）。
/// - `.special`: keycode 経由で libghostty にモード対応エンコードさせる（矢印等）。
enum ControlKey {
  case text(String)
  case special(UInt32, ghostty_input_mods_e)

  /// macOS 仮想キーコード（モード依存のナビゲーションキーのみ。これらは
  /// libghostty が keycode から正しいエスケープを組む＝application cursor mode 等に追従する）。
  private static let specialKeycodes: [String: UInt32] = [
    "enter": 36, "return": 36, "tab": 48, "escape": 53, "esc": 53, "space": 49,
    "backspace": 51, "delete": 117, "up": 126, "down": 125, "left": 123, "right": 124,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
  ]

  private static let modTokens: [String: ghostty_input_mods_e] = [
    "ctrl": GHOSTTY_MODS_CTRL, "control": GHOSTTY_MODS_CTRL,
    "alt": GHOSTTY_MODS_ALT, "opt": GHOSTTY_MODS_ALT, "option": GHOSTTY_MODS_ALT,
    "meta": GHOSTTY_MODS_ALT,
    "shift": GHOSTTY_MODS_SHIFT,
    "cmd": GHOSTTY_MODS_SUPER, "super": GHOSTTY_MODS_SUPER,
  ]

  static func parse(_ spec: String) -> ControlKey? {
    let parts = spec.lowercased().split(separator: "+").map(String.init)
    guard let base = parts.last, !base.isEmpty else { return nil }
    var mods: UInt32 = 0
    for token in parts.dropLast() {
      guard let m = modTokens[token] else { return nil }
      mods |= m.rawValue
    }
    let modFlags = ghostty_input_mods_e(rawValue: mods)

    if let keycode = specialKeycodes[base] {
      return .special(keycode, modFlags)
    }
    // 単一文字は修飾を端末バイトへ畳む（モード非依存）。ctrl→C0 制御、alt/meta→ESC プレフィックス。
    // cmd/super は端末バイト表現を持たないので拒否し、修飾を黙殺して素の文字を返さない。
    if base.count == 1, let scalar = base.unicodeScalars.first {
      if mods & GHOSTTY_MODS_SUPER.rawValue != 0 { return nil }
      var text = base
      if mods & GHOSTTY_MODS_CTRL.rawValue != 0 {
        let upper = scalar.value & ~0x20  // 'a'→'A'
        guard upper >= 0x40, upper <= 0x5F else { return nil }  // @A-Z[\]^_
        text = String(UnicodeScalar(upper & 0x1F)!)
      }
      if mods & GHOSTTY_MODS_ALT.rawValue != 0 {
        text = "\u{1b}" + text
      }
      return .text(text)
    }
    return nil
  }
}
