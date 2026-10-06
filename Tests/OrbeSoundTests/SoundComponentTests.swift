import XCTest

@testable import OrbeSound

/// LFO 語彙の数値検証。L1 純ロジック・決定論。
/// 壊れると深さの解釈（1−depth…1）が崩れて、トレモロが公称ゲインを超えるクリップ余地を作る。
final class SoundComponentTests: XCTestCase {

  /// トレモロ係数は 1−depth…1。上限が 1 に固定される（揺らしてもクリップ余地を作らない）。
  func testGainMultiplierStaysBetweenOneMinusDepthAndOne() {
    let lfo = LFO(rate: 1, depth: 0.4)
    XCTAssertEqual(lfo.gainMultiplier(at: 0.25), 1.0, accuracy: 1e-9, "山で公称のまま")
    XCTAssertEqual(lfo.gainMultiplier(at: 0.75), 0.6, accuracy: 1e-9, "谷で 1−depth")
  }
}
