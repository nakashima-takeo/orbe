import AppKit

/// ポインタの形・⌘ の URL の下線・俯瞰と区画のホバー。どれも窓のポインタの位置から、最前面の view がポインタを持つかを
/// 1 つの判定で決めて引く。
extension MetalTextView {
  /// ポインタの形と、本体の上のポインタ（つまみの見え隠れと帯・つまみの濃さ）。ドラッグ中も出入りを受ける——つまみを
  /// 押したまま本体の外で離せば、つまみが消える。
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [
          .cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect,
          .enabledDuringMouseDrag,
        ],
        owner: self))
  }

  /// 窓の hit-test がその点で自分（か配下）に解けるか。tracking area は重なった view を考慮しないので、手前に重なる
  /// view（面の取っ手など）の下では、ポインタの形も俯瞰のホバーも出さない——ポインタは最前面の view が持つ。
  private func ownsPointer(at windowPoint: NSPoint) -> Bool {
    window?.contentView?.hitTest(windowPoint)?.isDescendant(of: self) == true
  }

  /// 最前面のときだけポインタの形と ⌘ の URL の下線を出す。戻り値はポインタを持ったか。
  @discardableResult
  private func trackPointer(at windowPoint: NSPoint, flags: NSEvent.ModifierFlags) -> Bool {
    guard ownsPointer(at: windowPoint) else {
      surface?.setLinkPointer(nil)
      return false
    }
    pointer.updatePointer(at: windowPoint, flags: flags, in: self)
    return true
  }

  override func cursorUpdate(with event: NSEvent) {
    trackPointer(at: event.locationInWindow, flags: event.modifierFlags)
  }

  override func mouseMoved(with event: NSEvent) {
    hover(
      at: event.locationInWindow,
      inside: trackPointer(at: event.locationInWindow, flags: event.modifierFlags))
  }

  override func mouseEntered(with event: NSEvent) {
    hover(at: event.locationInWindow, inside: ownsPointer(at: event.locationInWindow))
  }

  override func mouseExited(with event: NSEvent) {
    surface?.setLinkPointer(nil)
    hover(at: event.locationInWindow, inside: false)
  }

  /// 窓の今のポインタの位置で、ポインタの形とホバーを引き直す（ポインタの下で押せる場所が動いた）。tracking area と同じく
  /// key window のときだけポインタを持ち、手前に重なる view の下では持たない。
  func refreshPointer() {
    guard let window else { return }
    let windowPoint = window.mouseLocationOutsideOfEventStream
    let inside =
      window.isKeyWindow && trackPointer(at: windowPoint, flags: NSEvent.modifierFlags)
    hover(at: windowPoint, inside: inside)
  }

  /// 俯瞰の上のポインタと、区画の押せる場所のホバー。
  private func hover(at windowPoint: NSPoint, inside: Bool) {
    let point = convert(windowPoint, from: nil)
    surface?.inputScope { overview.pointerMoved(to: point, inside: inside) }
    surface?.hover(at: inside ? point : nil)
  }

  override func flagsChanged(with event: NSEvent) {
    guard let window else { return super.flagsChanged(with: event) }
    trackPointer(at: window.mouseLocationOutsideOfEventStream, flags: event.modifierFlags)
    super.flagsChanged(with: event)
  }
}
