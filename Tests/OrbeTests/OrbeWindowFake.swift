import AppKit

@testable import Orbe

/// Orbe のウィンドウ（`OrbeWindow`）のフェイク。key かどうかをテストが決め、前面化は呼び出された回数を記録するだけで、
/// ウィンドウを画面に表示せずアプリも前面化しない。key の得失は AppKit と同じく、状態を変えてから通知を出すので、delegate と、
/// 通知を購読するビューの両方に届く。
/// AppKit の内部（`NSApp.keyWindow`・キーイベントの配送先）は、このフェイクが返す key かどうかの値を見ない。
final class OrbeWindowFake: OrbeWindow {
  var isKey = false {
    didSet {
      guard isKey != oldValue else { return }
      NotificationCenter.default.post(
        name: isKey ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification,
        object: self)
    }
  }
  private(set) var bringToFrontCount = 0

  override var isKeyWindow: Bool { isKey }
  override func bringToFront() { bringToFrontCount += 1 }
}
