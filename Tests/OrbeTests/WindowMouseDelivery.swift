import AppKit
import XCTest

extension OrbeTestCase {
  /// 窓座標（原点は左下）の点を、アプリの配送の口（`NSApp.sendEvent`）から押して離す。ローカルのイベントの監視も本物と
  /// 同じく見る。マウスは並んだ窓にしか届かないので、窓は `placeOffscreen` で並べておく。`clickCount` は何回目の押下か
  /// （2 ならダブルクリックの 2 回目）。イベントは今の時刻を持つ（SwiftUI のジェスチャーとホバーは時刻 0 のイベントを取りこぼす）。
  ///
  /// 離すイベントは、押下を送る前にキューへ入れる。文字を扱う部品（入力欄、選べる文字）は、押下を受けると、離すイベントが
  /// キューに来るまで待つマウスの追跡ループに入ることがある。その場合、離すイベントを後から送ると、押下を送った
  /// `sendEvent` が戻らない。追跡ループが取らずに残った離すイベントは、押下の後にキューから取り出して配る。テストが
  /// 押して離すを `NSApp.sendEvent` で送るのは、この関数だけにする（`.swiftlint.yml` の `test_mouse_delivery`）。
  func deliverClick(
    at location: NSPoint, in window: NSWindow, clickCount: Int = 1,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard window.isVisible else {
      return XCTFail("マウスは並んだ窓にしか届かない。先に placeOffscreen で並べる", file: file, line: line)
    }
    let now = ProcessInfo.processInfo.systemUptime
    let make = { (type: NSEvent.EventType) in
      NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: [],
        timestamp: now, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: clickCount,
        pressure: type == .leftMouseDown ? 1 : 0)!
    }
    NSApp.postEvent(make(.leftMouseUp), atStart: false)
    NSApp.sendEvent(make(.leftMouseDown))
    if let pending = NSApp.nextEvent(
      matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    {
      NSApp.sendEvent(pending)
    }
  }
}
