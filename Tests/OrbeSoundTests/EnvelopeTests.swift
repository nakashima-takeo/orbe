import XCTest

@testable import OrbeSound

/// エンベロープ語彙の数値検証。L1 純ロジック・決定論。
/// `.percussive` が従来の 3 イベント形（setValue → 指数立ち上がり → 指数減衰）と同一数式で
/// あることが要——ここが崩れると既存 12 案の聴感が一斉に変わる。
final class EnvelopeTests: XCTestCase {

  /// `.percussive` は 3 イベント形と全時刻で一致する（既存 12 案の聴感を保つ同一数式）。
  func testPercussiveMatchesTheThreeEventForm() {
    let attack = 0.004
    let duration = 0.5
    let gain = 0.15
    let param = Envelope.percussive(attack: attack)
      .automation(start: 0, duration: duration, scale: gain)
    var expected = AudioParam(AudioParam.zero, at: 0)
    expected.rampExponentially(to: gain, at: attack)
    expected.rampExponentially(to: AudioParam.zero, at: duration)
    for t in stride(from: 0.0, through: 0.6, by: 0.005) {
      XCTAssertEqual(param.value(at: t), expected.value(at: t), accuracy: 1e-12, "t=\(t)")
    }
  }

  /// `decay` を明示した `.percussive` は attack + decay の時点で消える（duration に縛られない）。
  func testPercussiveWithExplicitDecay() {
    let param = Envelope.percussive(attack: 0.01, decay: 0.2)
      .automation(start: 0, duration: 1.0, scale: 1)
    XCTAssertEqual(param.value(at: 0.01), 1, accuracy: 1e-12)
    XCTAssertEqual(param.value(at: 0.21), AudioParam.zero, accuracy: 1e-12)
    XCTAssertEqual(param.value(at: 0.5), AudioParam.zero, accuracy: 1e-12, "以降は保持")
  }

  /// ADSR: 各ブレークポイントに到達し、サステインは発音終了まで保持され、リリースで 0 へ落ちる。
  func testADSRReachesEveryBreakpointAndHoldsSustain() {
    let sustain = 0.6
    let param = Envelope.adsr(attack: 0.05, decay: 0.1, sustain: sustain, release: 0.2)
      .automation(start: 0, duration: 1.0, scale: 1)
    XCTAssertEqual(param.value(at: 0), AudioParam.zero, accuracy: 1e-12)
    XCTAssertEqual(
      param.value(at: 0.025), (AudioParam.zero + 1) / 2, accuracy: 1e-9, "立ち上がりは線形")
    XCTAssertEqual(param.value(at: 0.05), 1, accuracy: 1e-12, "attack の端点")
    XCTAssertEqual(param.value(at: 0.15), sustain, accuracy: 1e-12, "decay の端点")
    XCTAssertEqual(param.value(at: 0.5), sustain, accuracy: 1e-12, "サステインを保持")
    XCTAssertEqual(param.value(at: 1.0), sustain, accuracy: 1e-12, "発音終了まで保持")
    XCTAssertEqual(
      param.value(at: 1.1), (sustain + AudioParam.zero) / 2, accuracy: 1e-9, "リリースは線形")
    XCTAssertEqual(param.value(at: 1.2), AudioParam.zero, accuracy: 1e-12, "リリースの端点")
  }

  /// ゲート形（glide の既定）: 素早く立ち上がり、全長の 7 割まで平坦、終了 + release で消える。
  func testGateHoldsBetweenAttackAndSustainFraction() {
    let duration = 0.4
    let gain = 0.12
    let param = Envelope.gate(attack: 0.02, sustainFraction: 0.7, release: 0.15)
      .automation(start: 0, duration: duration, scale: gain)
    XCTAssertEqual(param.value(at: 0.02), gain, accuracy: 1e-12)
    XCTAssertEqual(param.value(at: 0.15), gain, accuracy: 1e-12, "平坦区間")
    XCTAssertEqual(param.value(at: duration * 0.7), gain, accuracy: 1e-12)
    // 減衰区間 [0.7d, d + 0.15] の中点は幾何平均（指数）。
    let middle = (duration * 0.7 + duration + 0.15) / 2
    XCTAssertEqual(
      param.value(at: middle), (gain * AudioParam.zero).squareRoot(), accuracy: 1e-9)
  }

  /// `.sweep` は始値から終値へ 1 本の指数で移り、以降は保持する。
  func testSweepMovesExponentiallyThenHolds() {
    let param = Envelope.sweep(from: 200, to: 800, endFraction: 0.5)
      .automation(start: 0, duration: 1.0)
    XCTAssertEqual(param.value(at: 0), 200, accuracy: 1e-12)
    XCTAssertEqual(param.value(at: 0.25), 400, accuracy: 1e-9, "指数の中点は幾何平均")
    XCTAssertEqual(param.value(at: 0.5), 800, accuracy: 1e-12)
    XCTAssertEqual(param.value(at: 0.9), 800, accuracy: 1e-12, "到達後は保持")
  }

  /// 点の時刻は fraction * duration + offset。比率と絶対秒を同じ列に混在できる。
  func testPointTimeMixesFractionAndOffset() {
    let envelope = Envelope.breakpoints([
      Envelope.Point(value: 0, curve: .step),
      Envelope.Point(fraction: 0.5, offset: 0.1, value: 1, curve: .linear),
    ])
    let param = envelope.automation(start: 0, duration: 2.0, scale: 1)
    XCTAssertEqual(param.value(at: 1.1), 1, accuracy: 1e-12, "0.5 * 2.0 + 0.1 = 1.1 で到達")
    XCTAssertLessThan(param.value(at: 1.0), 1, "手前ではまだ登り切っていない")
  }

  /// `end` は最後の点まで（リリースぶん伸びる）。ただし duration を下回らない
  /// ——最後の点の後も値は保持されて鳴り続けるため。
  func testEndCoversTheTailButNeverUndercutsDuration() {
    XCTAssertEqual(Envelope.percussive(attack: 0.004).end(duration: 0.5), 0.5, accuracy: 1e-12)
    XCTAssertEqual(
      Envelope.adsr(attack: 0.05, decay: 0.1, sustain: 0.6, release: 0.2).end(duration: 1.0),
      1.2, accuracy: 1e-12)
    XCTAssertEqual(Envelope.constant(700).end(duration: 0.3), 0.3, accuracy: 1e-12)
  }

  /// `.constant` だけが constantValue を持つ（noise がフィルタ係数を 1 度だけ組む判定）。
  func testConstantValueDetection() {
    XCTAssertEqual(Envelope.constant(700).constantValue, 700)
    XCTAssertNil(Envelope.sweep(from: 200, to: 800).constantValue)
    XCTAssertNil(Envelope.percussive(attack: 0.01).constantValue)
  }
}
