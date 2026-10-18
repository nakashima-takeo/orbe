import AppKit

/// 押し続けの守り。行の部品を押して錨を受け取った列が張る。ポインタが押した部品の枠 `frame`（窓の座標）の中に居る間、
/// その枠の中の左クリックの押下は、列が通すと答えたもの（留めている行の同じ部品）だけを通し、ほかは捨てる。続けて押して
/// いる位置に、留めきれずに見出し・別の区分の行が来ても、帯や失敗の文の出入りで列の外のもの（コミットボタン・帯の「止める」）
/// が来ても、その押下で何も起こさない。押下は窓の段で受ける——列の外の view に当たる押下も捨てるため。
///
/// ポインタが枠を出る・枠の外を押す・キー・ホイール・窓が key でなくなる・列が窓を離れる（`end`）と終わる。錨が外れても
/// 終わらない（ポインタはまだ押し続けの位置に居る）。
@MainActor
final class RowListPressGuard {
  private weak var window: NSWindow?
  private let frame: NSRect
  private let admits: (NSEvent) -> Bool
  private var monitor: Any?
  private var resignObserver: NSObjectProtocol?

  init(window: NSWindow, frame: NSRect, admits: @escaping (NSEvent) -> Bool) {
    self.window = window
    self.frame = frame
    self.admits = admits
    monitor = NSEvent.addLocalMonitorForEvents(
      matching: [
        .leftMouseDown, .mouseMoved, .leftMouseDragged, .mouseEntered, .mouseExited, .keyDown,
        .scrollWheel,
      ]
    ) { [weak self] event in
      MainActor.assumeIsolated { self.map { $0.filter(event) } ?? event }
    }
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.end() }
    }
  }

  deinit {
    MainActor.assumeIsolated { end() }
  }

  /// 守りの最中か。
  var isActive: Bool { monitor != nil }

  /// 守りを終える。
  func end() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    resignObserver = nil
  }

  /// 窓の押下を通すか捨てるか（nil で捨てる）。ほかの窓のイベントには触らない。
  private func filter(_ event: NSEvent) -> NSEvent? {
    guard let window, event.window === window else { return event }
    switch event.type {
    case .leftMouseDown:
      guard frame.contains(event.locationInWindow) else {
        end()
        return event
      }
      return admits(event) ? event : nil
    case .keyDown, .scrollWheel:
      end()
    default:
      if !frame.contains(event.locationInWindow) { end() }
    }
    return event
  }
}
