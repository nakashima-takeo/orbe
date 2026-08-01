import AppKit
import GhosttyKit

/// マウス / スクロール入力を libghostty へ橋渡しする。
extension SurfaceView {
  private func mousePos(_ event: NSEvent) {
    guard let surface = surfacePtr else { return }
    let p = convert(event.locationInWindow, from: nil)
    // ghostty は top-left 原点を期待。NSView は bottom-left なので y を反転。
    ghostty_surface_mouse_pos(surface, p.x, bounds.height - p.y, ghosttyMods(event.modifierFlags))
  }

  override func mouseMoved(with event: NSEvent) { mousePos(event) }
  override func mouseDragged(with event: NSEvent) { mousePos(event) }

  /// mouseMoved / mouseEntered を受けるための tracking area。これが無いと mouseMoved が
  /// 一切呼ばれず libghostty にマウス位置が伝わらないため、マウスレポート有効な TUI
  /// （Claude Code 等）でクリックするまでスクロールが効かない（位置が viewport 内に
  /// 確立されるまで libghostty はマウスレポートを送らない）。`.inVisibleRect` で
  /// クリップ追従、`.activeAlways` で非キー時もレポートを通す。
  override func updateTrackingAreas() {
    trackingAreas.forEach { removeTrackingArea($0) }
    super.updateTrackingAreas()
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways],
        owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) {
    // enter で viewport 内に位置を確立する。マウスレポート送出可否がこの位置に依存する。
    mousePos(event)
  }

  override func mouseExited(with event: NSEvent) {
    // ドラッグ中は viewport 外でも mouseDragged が来るので送らない。
    guard NSEvent.pressedMouseButtons == 0, let surface = surfacePtr else { return }
    // 負値で viewport を出たことを通知（本家準拠）。
    ghostty_surface_mouse_pos(surface, -1, -1, ghosttyMods(event.modifierFlags))
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    mousePos(event)
    guard let surface = surfacePtr else { return }
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, ghosttyMods(event.modifierFlags))
  }
  override func mouseUp(with event: NSEvent) {
    mousePos(event)
    guard let surface = surfacePtr else { return }
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, ghosttyMods(event.modifierFlags))
  }

  // 右・その他ボタンも surface へ橋渡しする。マウスレポート有効な TUI（tmux/vim/htop）で
  // 右クリック・中クリックを効かせるため。フォーカス移動は左クリックのみ（現状踏襲）。
  override func rightMouseDown(with event: NSEvent) {
    sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event)
  }
  override func rightMouseUp(with event: NSEvent) {
    sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event)
  }
  override func otherMouseDown(with event: NSEvent) {
    sendMouseButton(GHOSTTY_MOUSE_PRESS, Self.mouseButton(event.buttonNumber), event)
  }
  override func otherMouseUp(with event: NSEvent) {
    sendMouseButton(GHOSTTY_MOUSE_RELEASE, Self.mouseButton(event.buttonNumber), event)
  }

  private func sendMouseButton(
    _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent
  ) {
    mousePos(event)
    guard let surface = surfacePtr else { return }
    _ = ghostty_surface_mouse_button(surface, state, button, ghosttyMods(event.modifierFlags))
  }

  /// NSEvent の buttonNumber を libghostty のボタン enum へ（上流 Ghostty.Input.MouseButton 準拠）。
  private static func mouseButton(_ buttonNumber: Int) -> ghostty_input_mouse_button_e {
    switch buttonNumber {
    case 0: return GHOSTTY_MOUSE_LEFT
    case 1: return GHOSTTY_MOUSE_RIGHT
    case 2: return GHOSTTY_MOUSE_MIDDLE
    case 3: return GHOSTTY_MOUSE_EIGHT  // Back
    case 4: return GHOSTTY_MOUSE_NINE  // Forward
    case 5: return GHOSTTY_MOUSE_SIX
    case 6: return GHOSTTY_MOUSE_SEVEN
    case 7: return GHOSTTY_MOUSE_FOUR
    case 8: return GHOSTTY_MOUSE_FIVE
    case 9: return GHOSTTY_MOUSE_TEN
    case 10: return GHOSTTY_MOUSE_ELEVEN
    default: return GHOSTTY_MOUSE_UNKNOWN
    }
  }

  /// delta を pending に蓄積して即 return し、次 run loop tick の合体 flush へ回す。
  /// 重い pty 出力中（IO スレッドが `renderer_state.mutex` を握る状況）に
  /// `ghostty_surface_mouse_scroll` を同期呼び出しすると、mutex 待ちでブロックした隙に
  /// AppKit が後続の scrollWheel を coalescing して delta を取りこぼす。受理を mutex 待ちから
  /// 切り離し、libghostty 呼び出しを次 tick に分離することで併合起点をこのメソッドから消す。
  override func scrollWheel(with event: NSEvent) {
    var x = event.scrollingDeltaX
    var y = event.scrollingDeltaY
    let precision = event.hasPreciseScrollingDeltas
    if precision {
      // トラックパッド等のピクセル単位デルタ。本家同様に主観的な 2x 倍率を掛ける。
      x *= 2
      y *= 2
    }

    pendingScrollX += x
    pendingScrollY += y
    pendingScrollMods = scrollMods(precision: precision, phase: event.momentumPhase)

    guard !scrollFlushScheduled else { return }
    scrollFlushScheduled = true
    DispatchQueue.main.async { [weak self] in self?.flushScroll() }
  }

  /// 蓄積した scroll delta を 1 回の `ghostty_surface_mouse_scroll` で libghostty へ反映する。
  /// scrollWheel も flush も main スレッドなので、呼び出しが mutex 競合でブロックしてもその間に
  /// scrollWheel が再入することはない（イベントはキューに積まれ、解除後に実行・再蓄積される）。
  /// 取りこぼしを消すのはクリア順序ではなく scrollWheel を非ブロック化したこと自体。flush 自身が
  /// ブロックする窓では窓サーバ側の coalescing が残るが、その分は次 flush に合算され遅延に丸まる。
  func flushScroll() {
    scrollFlushScheduled = false
    guard let surface = surfacePtr, pendingScrollX != 0 || pendingScrollY != 0 else { return }

    let x = pendingScrollX
    let y = pendingScrollY
    let mods = pendingScrollMods
    pendingScrollX = 0
    pendingScrollY = 0

    ghostty_surface_mouse_scroll(surface, x, y, mods)
  }

  /// precision/momentum を libghostty の packed `ghostty_input_scroll_mods_t` に詰める。
  /// bit0 = precision、bit1..3 = momentum phase。precision を立てないと libghostty が
  /// ピクセルデルタを行数として解釈してしまい、スクロールが爆速になる。
  private func scrollMods(precision: Bool, phase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
    var value: Int32 = 0
    if precision { value |= 0b0000_0001 }
    let momentum: ghostty_input_mouse_momentum_e
    switch phase {
    case .began: momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
    case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
    case .changed: momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
    case .ended: momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
    case .cancelled: momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
    case .mayBegin: momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
    default: momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
    }
    value |= Int32(momentum.rawValue) << 1
    return value
  }
}
