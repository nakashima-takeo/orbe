import XCTest

@testable import Orbe

/// ②到来アニメーションの**尺と時間挙動**を固定する。driver は時刻注入の状態機械なので、
/// 実時間を待たずに任意のフレームを再現できる（ここが本設計の検証可能性の土台）。
@MainActor
final class MenuBarArrivalTests: XCTestCase {

  /// 基準時刻は 0——注入する秒数がそのまま経過秒になり、境界（1.2s / 2.3s / 22.6s）の判定に
  /// 丸め誤差が混ざらない。
  private let t0 = Date(timeIntervalSinceReferenceDate: 0)

  private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

  /// C1: 尺は design 原典のタイムライン表どおり。滞留 22 秒だけが Orbe の意図的な逸脱。
  func testDurationsMatchDesign() {
    XCTAssertEqual(MenuBarArrival.expand, 0.84)
    XCTAssertEqual(MenuBarArrival.glossDelay, 1.2)
    XCTAssertEqual(MenuBarArrival.glossDuration, 1.1)
    XCTAssertEqual(MenuBarArrival.collapse, 0.6)
    XCTAssertEqual(AttentionStore.transientDwell, 22)
  }

  /// 展開は 840ms で開き切り、滞留の間は開いたまま。
  func testExpandReachesOpenAndHolds() {
    let driver = MenuBarArrivalDriver()
    driver.arrived(at: t0)
    XCTAssertEqual(driver.phase.openness, 0, accuracy: 0.001)
    driver.tick(now: at(0.42))
    XCTAssertEqual(driver.phase.openness, 0.5, accuracy: 0.001)
    driver.tick(now: at(0.84))
    XCTAssertEqual(driver.phase.openness, 1, accuracy: 0.001)
    driver.tick(now: at(21.9))
    XCTAssertEqual(driver.phase.openness, 1, accuracy: 0.001)
  }

  /// 収縮は滞留満了から 600ms。完了（＝②を落とす合図）を返すのは撃ち終えた tick だけ。
  func testCollapseTakesSixHundredMillisecondsAndReportsOnce() {
    let driver = MenuBarArrivalDriver()
    driver.arrived(at: t0)
    driver.tick(now: at(1))
    driver.expired(at: at(22))
    XCTAssertEqual(driver.phase.openness, 1, accuracy: 0.001)
    XCTAssertFalse(driver.tick(now: at(22.3)))
    XCTAssertEqual(driver.phase.openness, 0.5, accuracy: 0.001)
    XCTAssertTrue(driver.phase.closing, "収縮の途中は向きを持つ（easing が展開の逆再生にならない）")
    XCTAssertFalse(driver.tick(now: at(22.59)), "撃ち終える前は完了を返さない")
    XCTAssertTrue(driver.tick(now: at(22.6)))
    XCTAssertEqual(driver.phase.openness, 0, accuracy: 0.001)
    XCTAssertEqual(driver.phase, .closed, "閉じ切りは向きを持たない（両向きの見た目が一致する）")
    XCTAssertFalse(driver.tick(now: at(22.7)), "完了は 1 度だけ")
  }

  /// C5: 艶は 1 到来につき 1 回だけ、到来 1.2s 後から 1.1s かけて左端の外から右端の外へ抜ける。
  func testGlossSweepsOncePerArrival() throws {
    let driver = MenuBarArrivalDriver()
    driver.arrived(at: t0)
    driver.tick(now: at(0.5))
    XCTAssertNil(driver.phase.gloss, "1.2s 前は走らない")
    driver.tick(now: at(1.2))
    XCTAssertEqual(try XCTUnwrap(driver.phase.gloss), 0, accuracy: 0.001)
    driver.tick(now: at(1.75))
    XCTAssertEqual(try XCTUnwrap(driver.phase.gloss), 0.5, accuracy: 0.01)
    driver.tick(now: at(2.29))
    XCTAssertEqual(try XCTUnwrap(driver.phase.gloss), 1, accuracy: 0.01)
    driver.tick(now: at(2.31))
    XCTAssertNil(driver.phase.gloss)
    for offset in [3.0, 5.0, 12.0, 22.0] {
      driver.tick(now: at(offset))
      XCTAssertNil(driver.phase.gloss, "t0+\(offset): 1 到来につき艶は 1 回だけ")
    }
  }

  /// C5: 滞留中の積み替えは艶をもう 1 回走らせるが、既に開いているので開き直さない。
  func testRestackReplaysGlossWithoutReopening() throws {
    let driver = MenuBarArrivalDriver()
    driver.arrived(at: t0)
    driver.tick(now: at(3))
    driver.arrived(at: at(5))
    XCTAssertEqual(driver.phase.openness, 1, accuracy: 0.001, "再展開しない")
    driver.tick(now: at(5.5))
    XCTAssertNil(driver.phase.gloss)
    driver.tick(now: at(6.2))
    XCTAssertEqual(try XCTUnwrap(driver.phase.gloss), 0, accuracy: 0.001)
    driver.tick(now: at(6.75))
    XCTAssertEqual(try XCTUnwrap(driver.phase.gloss), 0.5, accuracy: 0.01)
    XCTAssertEqual(driver.phase.openness, 1, accuracy: 0.001)
  }

  /// C7: 取り下げ・②中のクリックは即時。tick を待たずに閉じ切り、tween も残さない。
  func testDismissClosesImmediately() {
    let driver = MenuBarArrivalDriver()
    driver.arrived(at: t0)
    driver.tick(now: at(1.5))
    driver.dismissed()
    XCTAssertEqual(driver.phase, .closed)
    XCTAssertFalse(driver.isAnimating)
  }

  /// C8: Reduce Motion では位相が 0 と 1 しか取らず、艶は 1 度も走らず、ticker も回らない。
  /// 情報は落ちない——②は開いた姿で滞留し、閉じた瞬間に件数が現れる。
  func testReduceMotionSkipsEveryTween() {
    let driver = MenuBarArrivalDriver()
    driver.reduceMotion = true
    driver.arrived(at: t0)
    XCTAssertEqual(driver.phase, .open)
    XCTAssertFalse(driver.isAnimating)
    for offset in [0.42, 1.75, 5.0, 22.0] {
      driver.tick(now: at(offset))
      XCTAssertEqual(driver.phase, .open, "t0+\(offset)")
      XCTAssertFalse(driver.isAnimating, "t0+\(offset)")
    }
    driver.expired(at: at(22))
    XCTAssertEqual(driver.phase, .closed)
    XCTAssertFalse(driver.isAnimating)
    XCTAssertTrue(driver.tick(now: at(22)), "収縮を待たずその場で②を落とす")
  }

  /// C9: ticker が回るのは展開＋艶（最大 2.3s）と収縮（0.6s）の間だけ。滞留 22 秒は止まる
  /// ——60Hz の `statusItem.length` 書き込みはメニューバー他アイテムの再配置を誘発する。
  func testTickerIdlesDuringDwell() {
    let driver = MenuBarArrivalDriver()
    driver.arrived(at: t0)
    XCTAssertTrue(driver.isAnimating)
    driver.tick(now: at(2.3))
    XCTAssertTrue(driver.isAnimating, "艶が走り切るまでは回る")
    driver.tick(now: at(2.31))
    XCTAssertFalse(driver.isAnimating)
    for offset in [5.0, 15.0] {
      driver.tick(now: at(offset))
      XCTAssertFalse(driver.isAnimating, "t0+\(offset): 滞留中は止まる")
    }
    driver.expired(at: at(22))
    XCTAssertTrue(driver.isAnimating)
    driver.tick(now: at(22.6))
    XCTAssertFalse(driver.isAnimating)
  }
}
