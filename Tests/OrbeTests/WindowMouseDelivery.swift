import AppKit
import XCTest

extension OrbeTestCase {
  /// 窓座標（原点は左下）の点を、アプリの配送の口（`NSApp.sendEvent`）から押して離す。ローカルのイベントの監視も本物と
  /// 同じく見る。マウスは並んだ窓にしか届かないので、窓は `placeOffscreen` で並べておく。`clickCount` は何回目の押下か
  /// （2 ならダブルクリックの 2 回目）。イベントは今の時刻を持つ（SwiftUI のジェスチャーとホバーは時刻 0 のイベントを取りこぼす）。
  ///
  /// 離すイベントは、押下を送る前にキューへ入れる。文字を扱う部品（入力欄、選べる文字）は、押下を受けると、離すイベントが
  /// キューに来るまで待つマウスの追跡ループに入ることがある。窓を並べてランループを回した後の押下は、macOS 26 では入り、
  /// macOS 27 では入らない。macOS 27 でも、作ってからランループを回していない窓への押下は入る（テストの足場の外の使い捨ての
  /// テストで確かめた）。追跡ループに入った場合、離すイベントを後から送ると、押下を送った `sendEvent` が戻らない。追跡
  /// ループが取らずにキューに残った離すイベントは、取り出して捨て、作った離すイベントそのものを配る。キューを経た離す
  /// イベントは AppKit が作り直したもので、macOS 26 では窓の座標が画面の座標に置き換わっていることがあり、画面外に並べた
  /// 窓では押した点から大きく外れて、SwiftUI のタップが成り立たない。追跡ループが取る離すイベントもキューを経るので、
  /// macOS 26 では位置が押した点から外れている見込みがある（確かめていない）。文字の部品の押した位置に依る結果（キャレットの
  /// 位置、選択の範囲）は、CI の macOS 26 で押した点と違いうる。
  /// テストが押して離すを `NSApp.sendEvent` で送るのは、この関数だけにする（`.swiftlint.yml` の `test_mouse_delivery`）。
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
    let up = make(.leftMouseUp)
    NSApp.postEvent(up, atStart: false)
    NSApp.sendEvent(make(.leftMouseDown))
    if NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
      != nil
    {
      NSApp.sendEvent(up)
    }
  }
}
