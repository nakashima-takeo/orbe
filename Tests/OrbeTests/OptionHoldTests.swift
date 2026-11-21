import AppKit
import XCTest

@testable import Orbe

/// ⌥ だけの長押しの判定（`OptionHoldDetector`）の仕様を固定する。成立 = ⌥ だけになってから間合いの間、ほかの入力が無く、
/// 期限の時点の実状態が ⌥ だけで窓が許すこと。成立中は実状態で確かめ、キー・⌥ 以外の修飾・離すことで終わる。
///
/// 壊れると何が起きるか。⌥クリック・⌥ドラッグ・⌥＋字・⌥⌘↑↓ のたびにエディターが消える。⌥ を離した知らせを取りこぼしたとき
/// （メニューを開いている間に離した）に端末が出たままになる。見送った押下の続きで、修飾を離しきる前に透かしが始まる。
final class OptionHoldTests: OrbeTestCase {
  private var detector = OptionHoldDetector()
  private let delay = OptionHoldDetector.delay

  private func press(at time: TimeInterval = 0, pointer: CGPoint = .zero, buttonDown: Bool = false)
  {
    detector.modifiersChanged(
      .optionOnly, mouseButtonDown: buttonDown, pointer: pointer, at: time)
  }

  private func expire(
    at time: TimeInterval? = nil, modifiers: OptionHoldDetector.Modifiers = .optionOnly,
    buttonDown: Bool = false, pointer: CGPoint = .zero, windowAllows: Bool = true
  ) {
    detector.expire(
      at: time ?? delay, modifiers: modifiers, mouseButtonDown: buttonDown, pointer: pointer,
      windowAllows: windowAllows)
  }

  // MARK: - 成立

  /// ⌥ だけを押して間合いが過ぎれば成立し、離せば終わる。
  func testHoldingOptionAloneBeginsAfterTheDelayAndEndsOnRelease() {
    press()
    XCTAssertEqual(detector.waitingSince, 0)
    XCTAssertFalse(detector.isHolding, "押した瞬間には成立しない")

    expire()
    XCTAssertTrue(detector.isHolding)

    detector.modifiersChanged(.none, mouseButtonDown: false, pointer: .zero, at: 1)
    XCTAssertFalse(detector.isHolding)
  }

  /// 成立中のマウスの押下では終わらない。
  func testMouseDuringTheHoldKeepsIt() {
    press()
    expire()
    detector.mouseDown()
    XCTAssertTrue(detector.isHolding)
  }

  /// 待ちの間のポインタの動きは許容の内なら成立を妨げない。
  func testPointerJitterWithinToleranceStillBegins() {
    press(pointer: CGPoint(x: 10, y: 10))
    expire(pointer: CGPoint(x: 12, y: 13))
    XCTAssertTrue(detector.isHolding)
  }

  // MARK: - 見送り

  /// 待ちの間のキー（⌥＋字）・マウスの押下（⌥クリック・⌥ドラッグ）は、その押下を見送る。
  func testInputWhileWaitingSkipsThePress() {
    press()
    detector.keyDown()
    expire()
    XCTAssertFalse(detector.isHolding, "⌥＋字")

    detector.modifiersChanged(.none, mouseButtonDown: false, pointer: .zero, at: 1)
    press(at: 2)
    detector.mouseDown()
    expire(at: 2 + delay)
    XCTAssertFalse(detector.isHolding, "⌥クリック")
  }

  /// 待ちの間にポインタが許容を越えて動いた（⌥クリックの狙いを付けている）なら成立しない。
  func testPointerMovedBeyondToleranceSkips() {
    press(pointer: .zero)
    expire(pointer: CGPoint(x: OptionHoldDetector.pointerTolerance + 1, y: 0))
    XCTAssertFalse(detector.isHolding)
  }

  /// 期限の時点の実状態が ⌥ だけでない・マウスのボタンが押されている・窓が許さないなら成立しない。
  func testDeadlineChecksTheActualStateAndTheWindow() {
    for (modifiers, buttonDown, allows) in [
      (OptionHoldDetector.Modifiers.none, false, true), (.other, false, true),
      (.optionOnly, true, true), (.optionOnly, false, false),
    ] {
      detector = OptionHoldDetector()
      press()
      expire(modifiers: modifiers, buttonDown: buttonDown, windowAllows: allows)
      XCTAssertFalse(detector.isHolding, "\(modifiers) / ボタン \(buttonDown) / 窓 \(allows)")
    }
  }

  /// マウスのボタンを押したまま ⌥ を押した（ドラッグ中の ⌥ でコピー）なら待ちに入らない。
  func testOptionPressedDuringADragSkips() {
    press(buttonDown: true)
    XCTAssertNil(detector.waitingSince)
    expire()
    XCTAssertFalse(detector.isHolding)
  }

  /// 見送った押下は、修飾を全部離すまで次を始めない（⌥⌘↑ の ⌘ を先に離して ⌥ が残っても透かさない）。
  func testSkippedPressWaitsUntilEveryModifierIsReleased() {
    detector.modifiersChanged(.other, mouseButtonDown: false, pointer: .zero, at: 0)
    press(at: 0.1)
    XCTAssertNil(detector.waitingSince, "⌘ を離して ⌥ だけ残っても待ちに入らない")

    detector.modifiersChanged(.none, mouseButtonDown: false, pointer: .zero, at: 0.2)
    press(at: 0.3)
    XCTAssertEqual(detector.waitingSince, 0.3, "全部離した後の押下は待ちに入る")
  }

  // MARK: - 終わり

  /// 成立中のキー・⌥ 以外の修飾で終わり、そのまま ⌥ が残っても再び成立しない。
  func testKeyOrAnotherModifierEndsTheHoldAndSkips() {
    press()
    expire()
    detector.keyDown()
    XCTAssertFalse(detector.isHolding, "キーで終わる")
    press(at: 1)
    XCTAssertNil(detector.waitingSince)

    detector = OptionHoldDetector()
    press()
    expire()
    detector.modifiersChanged(.other, mouseButtonDown: false, pointer: .zero, at: 1)
    XCTAssertFalse(detector.isHolding, "⌥⌘ で終わる")
  }

  /// 成立中の確かめは実状態を読み、離していれば終わる（離した知らせを取りこぼしても戻る）。
  func testCheckEndsTheHoldWhenTheActualStateChanged() {
    press()
    expire()
    detector.check(.optionOnly)
    XCTAssertTrue(detector.isHolding)
    detector.check(.none)
    XCTAssertFalse(detector.isHolding)
    press(at: 1)
    XCTAssertEqual(detector.waitingSince, 1, "離していたので次の押下から始められる")

    detector = OptionHoldDetector()
    press()
    expire()
    detector.check(.other)
    XCTAssertFalse(detector.isHolding)
    press(at: 1)
    XCTAssertNil(detector.waitingSince, "ほかの修飾が残っていたので全部離すまで始めない")
  }

  /// 打ち切り（窓が前面でなくなった）は、どの段階からも待機へ戻す。
  func testCancelReturnsToIdle() {
    press()
    expire()
    detector.cancel()
    XCTAssertFalse(detector.isHolding)
    press(at: 1)
    XCTAssertEqual(detector.waitingSince, 1)
  }

  // MARK: - 修飾の分類

  /// 左右の ⌥ は区別せず、capsLock・fn は見ない。
  func testClassifyIgnoresSideCapsLockAndFunction() {
    XCTAssertEqual(OptionHoldDetector.classify([]), .none)
    XCTAssertEqual(OptionHoldDetector.classify(.option), .optionOnly)
    XCTAssertEqual(OptionHoldDetector.classify([.option, .capsLock, .function]), .optionOnly)
    XCTAssertEqual(
      OptionHoldDetector.classify(
        NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)),
      .optionOnly, "右の ⌥")
    XCTAssertEqual(OptionHoldDetector.classify([.option, .command]), .other)
    XCTAssertEqual(OptionHoldDetector.classify(.shift), .other)
  }
}
