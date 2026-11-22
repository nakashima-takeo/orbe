import AppKit
import OrbeTestSupport
import XCTest

extension OrbeTestCase {
  /// 窓を名指しして keyDown を窓の `sendEvent` へ届ける。窓が OS の表示の並びに入っているか（`placeOffscreen` で並べたか）に
  /// 依らない。`NSApp.sendEvent` で送った keyDown は、並んでいない窓にも key になれない窓にも届かない。テストの窓
  /// （並べていない窓、画面外へ並べた窓）はどちらかに当たる。窓のキー等価の段とメインメニューの段は通らないので、⌘ キーの受け手を
  /// 確かめるテストは窓の `performKeyEquivalent` を直接呼ぶ。
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
    window.sendEvent(dequeued)
  }

  /// 呼ぶ前に main のキューへ積まれていた仕事を走らせ終え、その後に、保留中の SwiftUI の更新（`.onChange`、同じホストの
  /// 中の焦点の移動、`scrollTo`）を 1 回、同期に走らせる。本番の 1 周と同じ順（積まれていた仕事 → 更新）にする。
  /// モデルを書き換えただけでは更新は走らないので、キーを送らずに状態だけ変えた後にも呼ぶ（呼ばないと、更新の中でしか
  /// 起きない欠陥が再現しない）。
  ///
  /// 更新をレイアウトで走らせるのは、テストの窓を並べていないため。並べていない窓では、AppKit の表示の周期がレイアウトを
  /// 走らせず、AppKit のスクロール位置や寸法の変化も、レイアウトを呼ばないと SwiftUI へ届かない。
  ///
  /// 直後に確かめてよいのは、同じホストの中の、積まれていた仕事と 1 回の更新で届く結果だけ。新しく載せたビューへ焦点が
  /// 入るのは、条件で待つ。別のホストや端末から焦点を奪う効果は、実時間で見張る（`holds`）。
  func flush(_ window: NSWindow) {
    nextTurn()
    window.contentView?.layoutSubtreeIfNeeded()
  }
}
