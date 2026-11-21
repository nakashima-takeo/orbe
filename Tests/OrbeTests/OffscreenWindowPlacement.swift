import AppKit
import XCTest

extension OrbeTestCase {
  /// 物理画面の外の座標。並べない窓にも使う（窓が画面を持たない条件を揃える）。
  static let offscreenOrigin = NSPoint(x: -20000, y: -20000)

  /// 窓を物理画面の外へ並べる（`orderFront` で OS の表示の並びに入れる。AppKit の ordered-in）。マウス・ホイールのイベントを
  /// AppKit の配送（`NSApp.sendEvent`・`window.sendEvent`）でビューへ届けるテストだけが使う。AppKit は、並んでいない窓のビューへ
  /// これらのイベントを配らない。キーとフォーカスだけのテストは窓を並べない。
  ///
  /// ホイールでスクロールさせるテストは、窓を `OrbeWindowFake` にする。AppKit の `NSScrollView` は、どの画面にも
  /// 載っていない窓ではホイールでスクロールしない。`OrbeWindowFake` は、並べられているのにどの画面にも載っていない間だけ、
  /// `screen` で主ディスプレイを答える。
  ///
  /// 位置と並べ方はここが決める。key にせず、アプリを前面にせず、テストの終わりに並びから外す（`orderOut`）。タイトルバーのある窓は
  /// macOS が画面内へ押し戻すので並べない。key になれる窓は、クリックで key になり、アプリが前面になりうる。画面外へ並べた
  /// key になれる窓でそれが起きるかは確かめていないので、これも並べない。並べている間は、どのビューも最初のクリックを受ける
  /// （`FirstMouse`）。
  func placeOffscreen(_ window: NSWindow) {
    guard !window.styleMask.contains(.titled), !window.canBecomeKey else {
      return XCTFail("画面外へ並べられるのは、タイトルバーが無く key になれない窓だけ")
    }
    window.setFrameOrigin(Self.offscreenOrigin)
    window.orderFront(nil)
    FirstMouse.begin()
    addTeardownBlock {
      MainActor.assumeIsolated {
        XCTAssertFalse(
          NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "窓が画面と重なっている")
        window.orderOut(nil)
        FirstMouse.end()
      }
    }
  }
}

/// 画面外へ並べた窓の、どのビューにも最初のクリックを受けさせる（`NSView.acceptsFirstMouse` を true にする）。
///
/// macOS 26 の SwiftUI は、前面でないアプリの key でない窓へのクリックを窓の有効化のクリックとみなし、`NSHostingView` の
/// `acceptsFirstMouse` が false ならジェスチャへ渡さない（macOS 27 は渡す）。テストはアプリを前面にせず窓も key にしないので、
/// どのクリックもこれに当たる。`NSHostingView` を本番コードが自分の中で作る部品（`BoardView`）があり、テストからはサブクラスも
/// `allowsWindowActivationEvents` も差し込めない。窓を key と答えさせても（`isKeyWindow` の上書き）、`window.sendEvent` で
/// 送っても渡らないので、並べている間だけ `NSView` の実装を入れ替える。`NSHostingView` の実装はこの答えを引き継ぐ。
private enum FirstMouse {
  private nonisolated(unsafe) static var depth = 0
  private nonisolated(unsafe) static var original: IMP?

  private static var method: Method {
    class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:)))!
  }

  static func begin() {
    depth += 1
    guard depth == 1 else { return }
    let always: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
    original = method_setImplementation(method, imp_implementationWithBlock(always))
  }

  static func end() {
    depth -= 1
    guard depth == 0, let original else { return }
    method_setImplementation(method, original)
    self.original = nil
  }
}
