import AppKit
import XCTest

extension OrbeTestCase {
  /// 窓を名指しして keyDown を届ける。窓が OS の表示の並びに入っているか（`placeOffscreen` で並べたか）に依らない。
  /// `NSApp.sendEvent` はキーをアプリの key の窓へ配るので、テストの窓（並べていない窓、画面外へ並べた、key になれない窓）には
  /// 届かない。AppKit が key の窓へキーを配るのと同じ順——窓のキー等価、メインメニュー、窓の `sendEvent`——で渡す。
  ///
  /// 先にキューへ入れて取り出す。入力欄の ↵ の確定（`onSubmitIgnoringKeyRepeat`）は、キーリピートかどうかを
  /// `NSApp.currentEvent` で見るので、取り出さずに渡すと、前に取り出したキーが残って判定を狂わせる。ローカルイベントモニターは
  /// 通らない（`NSApp.sendEvent` の中でしか呼ばれない）。
  func deliverKeyDown(_ event: NSEvent, to window: NSWindow) {
    NSApp.postEvent(event, atStart: true)
    guard
      let dequeued = NSApp.nextEvent(
        matching: .keyDown, until: Date().addingTimeInterval(1), inMode: .default, dequeue: true)
    else { return XCTFail("キーイベントがキューから取れない") }
    if window.performKeyEquivalent(with: dequeued) { return }
    if NSApp.mainMenu?.performKeyEquivalent(with: dequeued) == true { return }
    window.sendEvent(dequeued)
  }
}
