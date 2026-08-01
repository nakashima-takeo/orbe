import AppKit
import GhosttyKit

// MARK: - キーボード入力（keyDown → keyAction → sendKeyEvent）

/// キー入力を IME・option-as-alt 翻訳を通して surface へ橋渡しする。
/// 上流 Ghostty の keyDown データフローに準拠する: `key.mods` には生 event、`interpretKeyEvents` と
/// text 生成・`consumed_mods` には `macos-option-as-alt` で翻訳した mods を使う。状態
/// （markedText / keyTextAccumulator）は SurfaceView 本体が持つ。
/// cf. vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift（keyDown/keyAction）、
/// NSEvent+Extension.swift（ghosttyKeyEvent/ghosttyCharacters）、Ghostty.Input.swift（eventModifierFlags）。
extension SurfaceView {
  override func keyDown(with event: NSEvent) {
    // 補完 popup 表示中は popup が ↑/↓/⌘↑/⌘↓/Esc を先取り（端末の chrome キーより優先）。
    // popup 非表示時は completionHandleKey が false を返し、従来どおり chrome→surface へ流れる。
    if completionHandleKey(event) { return }
    // chrome キーを先取り（surface へ転送しない）
    if let action = Keybindings.chromeAction(for: event) {
      perform(action)
      return
    }
    // IME を通す: interpretKeyEvents が setMarkedText（preedit）/ insertText（確定）/
    // doCommandBySelector（Enter・BS 等）を呼び分ける。その結果を踏まえて surface へ橋渡しする。
    keyAction(event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, event: event)
  }

  override func keyUp(with event: NSEvent) {
    sendKeyEvent(GHOSTTY_ACTION_RELEASE, event: event, text: "", composing: false)
  }

  /// ghostty mods → NSEvent フラグの逆変換（`ghosttyMods` の対）。
  /// `ghostty_surface_key_translation_mods`（macos-option-as-alt）が返す translation 用 mods を
  /// NSEvent フラグへ戻し、translationEvent の modifierFlags を組むのに使う。
  static func eventModifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
  }

  /// `macos-option-as-alt` に従い mods を翻訳した「翻訳イベント」を作る。
  /// `interpretKeyEvents` と text 生成にはこの翻訳済みイベントを渡し（option を alt として解釈させ、
  /// US 系レイアウトで Option+文字が `∫` 等ではなく Alt+文字になる）、`key.mods` には生 event を使う
  /// という上流の契約に合わせる。mods が不変なら元 event を再利用する（IME オブジェクト同一性のため）。
  private func translationEvent(for event: NSEvent, surface: ghostty_surface_t) -> NSEvent {
    let translated = ghostty_surface_key_translation_mods(surface, ghosttyMods(event.modifierFlags))
    let translationModsGhostty = Self.eventModifierFlags(translated)
    // dead key 用の隠しビットを保つため、4 フラグだけを exact に転写する。
    var translationMods = event.modifierFlags
    for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
      if translationModsGhostty.contains(flag) {
        translationMods.insert(flag)
      } else {
        translationMods.remove(flag)
      }
    }
    if translationMods == event.modifierFlags { return event }
    return NSEvent.keyEvent(
      with: event.type, location: event.locationInWindow,
      modifierFlags: translationMods, timestamp: event.timestamp,
      windowNumber: event.windowNumber, context: nil,
      characters: event.characters(byApplyingModifiers: translationMods) ?? "",
      charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
      isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
  }

  /// interpretKeyEvents を回し、IME の結果に応じて surface へキーを送る。
  /// 確定文字（insertText）があればそれを composing=false で送り、無ければ生キーを送る
  /// （composition 中なら composing=true → ghostty が端末出力を抑制し生ローマ字の漏れを防ぐ）。
  private func keyAction(_ action: ghostty_input_action_e, event: NSEvent) {
    guard let surface = surfacePtr else { return }
    // option-as-alt を反映した翻訳イベント。IME・text 生成・consumed_mods はこれを基準にし、
    // key.mods には生 event を使う（上流の keyDown データフロー）。
    let tEvent = translationEvent(for: event, surface: surface)
    keyTextAccumulator = []
    defer { keyTextAccumulator = nil }

    // interpretKeyEvents が preedit 最後の 1 文字で unmarkText() を呼ぶと markedText が空になる。
    // 評価後の markedText だけで composing を判定すると Backspace が確定文字へ貫通するため、
    // 回す前の composition 状態を退避して OR する。
    let composingBefore = markedText.length > 0
    interpretKeyEvents([tEvent])

    if let texts = keyTextAccumulator, !texts.isEmpty {
      for text in texts {
        sendKeyEvent(
          action, event: event, translationMods: tEvent.modifierFlags, text: text, composing: false)
      }
    } else {
      sendKeyEvent(
        action, event: event, translationMods: tEvent.modifierFlags, text: ghosttyText(tEvent),
        composing: markedText.length > 0 || composingBefore)
    }
  }

  /// surface へ渡すテキスト。関数キー（PUA 0xF700–0xF8FF）は矢印・Home/End 等の特殊キーで、
  /// text に乗せると Kitty キーボードプロトコル下で生 PUA 文字がそのまま端末へ漏れる
  /// （libghostty が keycode から正しいエスケープを組むべき）ため除外する。制御文字（<0x20）は
  /// その符号化を libghostty が自前で行うので、control を外した文字へ再導出する。
  private func ghosttyText(_ event: NSEvent) -> String {
    guard let chars = event.characters else { return "" }
    if chars.count == 1, let scalar = chars.unicodeScalars.first {
      if scalar.value < 0x20 {
        return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
          ?? ""
      }
      if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return "" }
    }
    return chars
  }

  /// text を `key.text` に載せてよいか。制御文字（先頭 UTF-8 バイト < 0x20）は載せず keycode のみで
  /// 送り、符号化を libghostty に委ねる（載せると effectiveMods が「text 有り」分岐で consumed_mods を
  /// 差し引き Alt+Enter が潰れる）。scalar でなくバイトで判定するのでマルチバイト UTF-8 は常に載る。
  static func textCarriesToKey(_ text: String) -> Bool {
    guard let first = text.utf8.first else { return false }
    return first >= 0x20
  }

  private func sendKeyEvent(
    _ action: ghostty_input_action_e, event: NSEvent,
    translationMods: NSEvent.ModifierFlags? = nil, text: String, composing: Bool
  ) {
    guard let surface = surfacePtr else { return }
    // 無修飾の codepoint。charactersIgnoringModifiers は ctrl 押下で挙動が変わるため使わず、
    // 上流と同じく byApplyingModifiers([]) で無修飾文字を取る（keyDown/keyUp でのみ有効）。
    let unshifted = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
    var key = ghostty_input_key_s()
    key.action = action
    key.mods = ghosttyMods(event.modifierFlags)
    // text 変換に control/command は寄与しない、それ以外は消費されたとみなす上流ヒューリスティック。
    // consumed_mods は translation 済み mods（option-as-alt 反映後）から算出する。生 mods で算出すると
    // effectiveMods が Alt を差し引き Option+Enter が素の Enter に潰れる。consumed_mods=0 だと
    // Kitty プロトコル下で Shift/Option が二重適用されうる。
    key.consumed_mods = ghosttyMods(
      (translationMods ?? event.modifierFlags).subtracting([.control, .command]))
    key.keycode = UInt32(event.keyCode)
    key.unshifted_codepoint = unshifted
    key.composing = composing
    if Self.textCarriesToKey(text) {
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
