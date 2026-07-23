import XCTest

@testable import Orbe

/// ⌘ 素タップ×2 判定（`CmdDoubleTapDetector`）の仕様を固定する。
/// 素タップ = 修飾なし→⌘のみ→修飾なしで、押下↔解放の間に keyDown/mouseDown/他修飾が挟まらないこと。
/// 発火 = 1 回目の解放→2 回目の解放が 350ms 以内で、2 回目の解放の瞬間。
final class CmdDoubleTapTests: XCTestCase {
  private var detector = CmdDoubleTapDetector()

  /// ⌘ を押して離す素タップ 1 回ぶんを流す。戻り値は解放時の発火判定。
  @discardableResult
  private func tap(down: TimeInterval, up: TimeInterval) -> Bool {
    _ = detector.flagsChanged(.commandOnly, at: down)
    return detector.flagsChanged(.none, at: up)
  }

  // MARK: 成立

  func testCleanDoubleTapFires() {
    XCTAssertFalse(tap(down: 0.00, up: 0.05))
    XCTAssertTrue(tap(down: 0.15, up: 0.25), "2 回目の解放で発火する")
  }

  /// 間隔は解放→解放で測る。境界（ちょうど 350ms）は成立。
  func testReleaseIntervalBoundaryFires() {
    XCTAssertFalse(tap(down: 0.00, up: 0.10))
    XCTAssertTrue(tap(down: 0.20, up: 0.45), "0.45 - 0.10 = 0.35 は境界内")
  }

  /// ⌘ の長押し 2 回でも keyDown が無ければ成立する（間隔は解放同士で測る）。
  func testLongPressTapsStillFire() {
    XCTAssertFalse(tap(down: 0.0, up: 2.0))  // 長押し 1 回目
    XCTAssertTrue(tap(down: 2.1, up: 2.3))
  }

  /// 発火後は状態がリセットされ、続けてもう 1 往復では発火しない（3 回目のタップが 1 回目になる）。
  func testStateResetsAfterFire() {
    tap(down: 0.0, up: 0.1)
    XCTAssertTrue(tap(down: 0.2, up: 0.3))
    XCTAssertFalse(tap(down: 0.4, up: 0.5), "発火直後の 1 タップでは発火しない")
    XCTAssertTrue(tap(down: 0.6, up: 0.7), "その次のタップで再び発火する")
  }

  /// 2 回目の解放が遅すぎたとき、その解放は「新しい 1 回目の解放」として次に生きる。
  func testLateSecondReleaseStartsNewSequence() {
    XCTAssertFalse(tap(down: 0.0, up: 0.1))
    XCTAssertFalse(tap(down: 0.2, up: 1.0), "0.9s 間隔は不成立")
    XCTAssertTrue(tap(down: 1.1, up: 1.2), "遅れた解放を 1 回目として次のタップで成立")
  }

  // MARK: 不成立

  /// 押下中の keyDown（⌘C 等）はそのタップも次の解放も無効（⌘ 解放を開始点にしない）。
  func testKeyDownDuringPressInvalidates() {
    _ = detector.flagsChanged(.commandOnly, at: 0.0)
    detector.keyDown()  // ⌘C
    XCTAssertFalse(detector.flagsChanged(.none, at: 0.1))
    XCTAssertFalse(tap(down: 0.2, up: 0.3), "汚れたタップは 1 回目に数えない")
    XCTAssertTrue(tap(down: 0.4, up: 0.5), "クリーンな 2 タップ目で成立する")
  }

  /// ⌘C→⌘V の速い連打で発火しない。
  func testFastCmdCVDoesNotFire() {
    _ = detector.flagsChanged(.commandOnly, at: 0.0)
    detector.keyDown()  // C
    XCTAssertFalse(detector.flagsChanged(.none, at: 0.05))
    _ = detector.flagsChanged(.commandOnly, at: 0.10)
    detector.keyDown()  // V
    XCTAssertFalse(detector.flagsChanged(.none, at: 0.15))
  }

  /// タップ間（解放後）の keyDown も不成立に落とす。
  func testKeyDownBetweenTapsInvalidates() {
    tap(down: 0.0, up: 0.05)
    detector.keyDown()
    XCTAssertFalse(tap(down: 0.1, up: 0.2))
  }

  /// mouseDown も keyDown と同じ扱い。
  func testMouseDownDuringPressInvalidates() {
    _ = detector.flagsChanged(.commandOnly, at: 0.0)
    detector.mouseDown()
    XCTAssertFalse(detector.flagsChanged(.none, at: 0.1))
    XCTAssertFalse(tap(down: 0.15, up: 0.2))
  }

  /// 他修飾が挟まる（⌘⇧ 等）と不成立。修飾の全解放までは新しいタップを始めない。
  func testOtherModifierPoisonsUntilAllReleased() {
    _ = detector.flagsChanged(.commandOnly, at: 0.0)
    _ = detector.flagsChanged(.other, at: 0.02)  // ⇧ が加わった
    XCTAssertFalse(detector.flagsChanged(.commandOnly, at: 0.04), "⇧ を離しても開始しない")
    XCTAssertFalse(detector.flagsChanged(.none, at: 0.06))
    XCTAssertFalse(tap(down: 0.1, up: 0.15), "全解放後の 1 タップ目では発火しない")
    XCTAssertTrue(tap(down: 0.2, up: 0.25))
  }

  /// ⌘Tab 相当（⌘押下→keyDown→他アプリへ）でも、以後のクリーンな 2 タップだけで発火する。
  func testCmdTabThenCleanTapsFires() {
    _ = detector.flagsChanged(.commandOnly, at: 0.0)
    detector.keyDown()  // Tab
    XCTAssertFalse(detector.flagsChanged(.none, at: 0.3))
    XCTAssertFalse(tap(down: 0.4, up: 0.45))
    XCTAssertTrue(tap(down: 0.5, up: 0.55))
  }
}
