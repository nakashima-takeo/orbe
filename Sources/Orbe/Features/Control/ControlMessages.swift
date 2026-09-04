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

/// 外部 → Orbe の制御で起きた出来事。`wait_for_event` がフィルタして待ち、`prompt_agent` /
/// `spawn_agent` の待機もこれで起きる。生の PTY 出力は libghostty が host に出さないため、
/// 扱えるのは whitelist された OSC 由来シグナル（agent 状態・タイトル・cwd）とペインの
/// ライフサイクルに限る。case ごとの payload は遷移時点の報告そのもの——配信時にペインを
/// 読み直すと done→idle 消費や次の遷移と競合するので、イベントが運ぶ。
enum ControlEvent {
  /// 導出 `agentState` の実変化。`state` nil は報告の消滅（SessionEnd）。`message` / `sessionId` は
  /// その遷移の報告が運んだもの。
  case agentState(paneId: Int, state: String?, message: String?, sessionId: String?)
  case paneTitle(paneId: Int, title: String)
  case pwd(paneId: Int, path: String?)
  case paneClosed(paneId: Int)

  /// `wait_for_event` が受け付ける kind の全体。フィルタの語彙はここが唯一の出所で、
  /// 未知の語は `waitForEvent` が待機を張る前に -32602 で弾く（黙って時間切れにしない）。
  static let kinds: Set<String> = ["agent_state", "pane_title", "pwd", "pane_closed"]

  var kind: String {
    switch self {
    case .agentState: return "agent_state"
    case .paneTitle: return "pane_title"
    case .pwd: return "pwd"
    case .paneClosed: return "pane_closed"
    }
  }

  var paneId: Int {
    switch self {
    case .agentState(let paneId, _, _, _), .paneTitle(let paneId, _), .pwd(let paneId, _),
      .paneClosed(let paneId):
      return paneId
    }
  }

  /// kind 固有の値（agent_state なら状態語、pane_title ならタイトル、pwd なら path）。
  /// 報告の消滅は `report_agent` の入力語と同じ `clear`——`wait_for_event` の `value` と
  /// `prompt_agent` の `state` が同じ語で一致するように、語はここだけが持つ。
  var value: String? {
    switch self {
    case .agentState(_, let state, _, _): return state ?? "clear"
    case .paneTitle(_, let title): return title
    case .pwd(_, let path): return path
    case .paneClosed: return nil
    }
  }

  func toDict() -> [String: Any] {
    var d: [String: Any] = ["kind": kind, "paneId": paneId]
    if let value { d["value"] = value }
    if case .agentState(_, _, let message, let sessionId) = self {
      if let message { d["message"] = message }
      if let sessionId { d["sessionId"] = sessionId }
    }
    return d
  }
}

/// 発番済みのイベント。履歴・配信・イベントで完結する応答の単位。
struct ControlEventRecord {
  let seq: Int
  let event: ControlEvent

  func toDict() -> [String: Any] {
    var d = event.toDict()
    d["seq"] = seq
    return d
  }
}

/// 待機動詞（wait_for_event / prompt_agent / spawn_agent / resume_agent）の `timeoutMs` 検証。
/// 既定値は動詞ごとに違うので呼び出し側が渡す。
enum WaitTimeout {
  /// 上限を置くのは、巨大値だと `.milliseconds(_:)` の deadline が DISPATCH_TIME_FOREVER まで
  /// 飽和してタイマーが発火しなくなるため——応答も時間切れも返らない待機が残る。
  /// 24 時間はベンチマークの最長（分オーダー）を十分に超える。
  static let maxMs = 86_400_000

  /// 省略なら既定、正の Int で上限内ならその値、それ以外は nil（呼び出し側が -32602）。
  static func parse(_ params: [String: Any], default defaultMs: Int) -> Int? {
    guard let raw = params["timeoutMs"] else { return defaultMs }
    guard let ms = raw as? Int, ms > 0, ms <= maxMs else { return nil }
    return ms
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

  /// `prompt_agent` が送信文の後に押す Enter（`parse("enter")` と同じ 1 打）。
  static let enter = input(for: NamedKey(kVK_Return), mods: 0)

  private static func input(for named: NamedKey, mods: UInt32) -> SurfaceKeyInput {
    SurfaceKeyInput(
      keycode: named.keycode, text: named.text, unshiftedCodepoint: named.unshiftedCodepoint,
      mods: ghostty_input_mods_e(rawValue: mods), consumedMods: ghostty_input_mods_e(rawValue: 0))
  }

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

    if let named = namedKeys[base] { return input(for: named, mods: mods) }

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
