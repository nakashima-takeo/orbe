import AppKit
import XCTest

extension OrbeTestCase {
  /// 物理画面の外の座標。並べない窓にも使う（窓が画面を持たない条件を揃える）。
  static let offscreenOrigin = NSPoint(x: -20000, y: -20000)

  /// 窓を物理画面の外へ並べる（`orderFront` で OS の表示の並びに入れる。AppKit の ordered-in）。マウス・ホイールのイベントを
  /// AppKit の配送（`NSApp.sendEvent`・`window.sendEvent`）でビューへ届けるテストだけが使う。AppKit は、並んでいない窓のビューへ
  /// これらのイベントを配らない。キーとフォーカスだけのテストは窓を並べない。
  ///
  /// 位置と並べ方はここが決める。key にせず、アプリを前面にせず、テストの終わりに並びから外す（`orderOut`）。タイトルバーのある窓は
  /// macOS が画面内へ押し戻し、key になれる窓は最初のクリックが窓の有効化に使われてビューへ届かないので、どちらも並べない。
  func placeOffscreen(_ window: NSWindow) {
    guard !window.styleMask.contains(.titled), !window.canBecomeKey else {
      return XCTFail("画面外へ並べられるのは、タイトルバーが無く key になれない窓だけ")
    }
    window.setFrameOrigin(Self.offscreenOrigin)
    window.orderFront(nil)
    addTeardownBlock {
      MainActor.assumeIsolated {
        XCTAssertFalse(
          NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "窓が画面と重なっている")
        window.orderOut(nil)
      }
    }
  }
}
