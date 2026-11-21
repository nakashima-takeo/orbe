import AppKit
import XCTest

@testable import Orbe

/// ⌥ だけの長押しの monitor（`OptionHoldMonitor`）が、本物のイベントの経路とタイマーで判定を動かすこと——離した知らせを
/// 取りこぼしても成立中の確かめで終わる・待ちの間のクリックで見送る・成立中のキーはその配送より前に終わらせる。
///
/// 壊れると何が起きるか。メニューを開いている間や別のアプリへ移った後に ⌥ を離すと、端末が出たままになる。⌥クリックの後に
/// ⌥ を押し続けるとエディターが消える。透かしたまま打った字が、見えないエディターへ入る。
final class OptionHoldMonitorTests: OrbeTestCase {
  /// 画面に出さない窓の monitor と、成立・終わりの知らせの記録（知らせた時点の `isHolding`）。窓の条件はいつも許す——前面の窓か
  /// どうかは窓の側の条件で、`WindowControllerFacesTests` が見る。
  private final class Subject {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
      backing: .buffered, defer: false)
    let monitor: OptionHoldMonitor
    let option: OptionHoldDriver
    var changes: [Bool] = []

    init() {
      window.isReleasedWhenClosed = false
      monitor = OptionHoldMonitor(window: window)
      option = OptionHoldDriver(monitor, in: window)
      monitor.windowAllows = { true }
      monitor.onChange = { [unowned self] in changes.append(monitor.isHolding) }
    }
  }

  /// ⌥ を離した知らせが届かなくても（メニューを開いている間に離した）、成立中の確かめが実状態を読んで終わらせる。
  func testAMissedReleaseEndsTheHoldOnTheNextCheck() {
    let subject = Subject()
    subject.option.hold()
    XCTAssertEqual(subject.changes, [true], "前提")

    subject.option.actualModifiers = []
    subject.option.pump(
      upTo: OptionHoldDetector.checkInterval * 5, until: { !subject.monitor.isHolding })

    XCTAssertEqual(subject.changes, [true, false])
  }

  /// 待ちの間にクリックした（⌥クリック）なら、間合いが過ぎても透かさない。
  func testAClickWhileWaitingSkipsThePress() throws {
    let subject = Subject()
    subject.option.send(.option)
    let click = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: .option,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: subject.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1))

    NSApp.sendEvent(click)
    subject.option.pump(upTo: OptionHoldDetector.delay * 2)

    XCTAssertEqual(subject.changes, [])
  }

  /// 成立中にキーを打つと、そのイベントの配送の中で（local monitor は配送より前に呼ばれるので、キーが届く前に）終わりを知らせる。
  func testAKeyEndsTheHoldBeforeItIsDelivered() throws {
    let subject = Subject()
    subject.option.hold()
    XCTAssertEqual(subject.changes, [true], "前提")
    let key = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .option,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: subject.window.windowNumber, context: nil, characters: "π",
        charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))

    NSApp.sendEvent(key)

    XCTAssertEqual(subject.changes, [true, false])
  }
}
