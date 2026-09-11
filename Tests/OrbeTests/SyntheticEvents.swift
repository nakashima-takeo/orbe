import AppKit

/// responder へ直接届ける合成イベント（窓の `sendEvent` は通さない）。
extension NSEvent {
  /// `point` は窓座標。
  static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }

  static func key(_ chars: String, _ flags: NSEvent.ModifierFlags = .command) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: 0, windowNumber: 0, context: nil,
      characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!
  }
}

extension NSView {
  /// 窓座標で見た中心点。
  var centerInWindow: NSPoint {
    convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
  }
}
