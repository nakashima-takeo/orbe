import XCTest

@testable import OrbeSound

/// LFO 語彙の数値検証。L1 純ロジック・決定論。
/// 壊れるとビブラート／トレモロが鳴り始めに段差を作り、深さの解釈（1−depth…1）が崩れて
/// トレモロが公称ゲインを超えるクリップ余地を作る。
final class SoundComponentTests: XCTestCase {

  /// 0 から立ち上がり、1/4 周期で +1・1/2 で 0・3/4 で −1、周回後も同形。
  func testLFOHitsItsQuarterPeriodLandmarks() {
    let lfo = LFO(rate: 5, depth: 1)
    XCTAssertEqual(lfo.value(at: 0), 0, accuracy: 1e-12, "0 起点")
    XCTAssertEqual(lfo.value(at: 0.05), 1, accuracy: 1e-9, "1/4 周期")
    XCTAssertEqual(lfo.value(at: 0.1), 0, accuracy: 1e-9, "1/2 周期")
    XCTAssertEqual(lfo.value(at: 0.15), -1, accuracy: 1e-9, "3/4 周期")
    XCTAssertEqual(lfo.value(at: 0.25), 1, accuracy: 1e-9, "周回後")
  }

  /// t が微小に負でも 0 近傍から連続する。机上の値ではない——`frames` は開始フレームを
  /// 切り捨てるので、LFO は部品の最初のサンプルで最大 −1/rate 秒を受ける。ここが跳ぶと
  /// 鳴り始めに段差が出る。
  func testLFOIsContinuousAtSlightlyNegativeTime() {
    XCTAssertEqual(LFO(rate: 5, depth: 1).value(at: -2e-5), 0, accuracy: 1e-3)
  }

  /// トレモロ係数は 1−depth…1。上限が 1 に固定される（揺らしてもクリップ余地を作らない）。
  func testGainMultiplierStaysBetweenOneMinusDepthAndOne() {
    let lfo = LFO(rate: 1, depth: 0.4)
    XCTAssertEqual(lfo.gainMultiplier(at: 0.25), 1.0, accuracy: 1e-9, "山で公称のまま")
    XCTAssertEqual(lfo.gainMultiplier(at: 0.75), 0.6, accuracy: 1e-9, "谷で 1−depth")
  }
}
