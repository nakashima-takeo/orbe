import XCTest

@testable import Orbe

/// 通知音の合成プリミティブ（`SoundSynth`）の数値検証。L1 純ロジック・決定論。
/// design と音がズレたときに疑う 4 箇所——指数エンベロープの減衰区間長・帯域制限・biquad の Q 解釈・
/// コンプレッサの静特性——を、ここで数値として固定する。
final class SoundSynthTests: OrbeTestCase {

  // MARK: - AudioParam（指数ランプの起点は「直前のイベント」）

  /// tone のゲイン（setValue → ramp(a) → ramp(d)）。端点は宣言どおり、**減衰は `d` でなく `d - a`**
  /// の長さで進む——ここを取り違えると全案が一様に長く聞こえる。
  func testExponentialRampStartsAtPreviousEvent() {
    let attack = 0.004
    let duration = 0.5
    let gain = 0.15
    var param = AudioParam(AudioParam.zero, at: 0)
    param.rampExponentially(to: gain, at: attack)
    param.rampExponentially(to: AudioParam.zero, at: duration)

    XCTAssertEqual(param.value(at: 0), AudioParam.zero, accuracy: 1e-12, "起点は 0.0001（ゼロ代わり）")
    XCTAssertEqual(param.value(at: attack), gain, accuracy: 1e-12, "立ち上がりの端点")
    XCTAssertEqual(param.value(at: duration), AudioParam.zero, accuracy: 1e-12, "減衰の端点")
    XCTAssertEqual(param.value(at: duration + 1), AudioParam.zero, accuracy: 1e-12, "以降は保持")

    // 減衰の中点は幾何平均。区間は [a, d] なのでその中央は (a+d)/2。
    let middle = (attack + duration) / 2
    XCTAssertEqual(
      param.value(at: middle), (gain * AudioParam.zero).squareRoot(), accuracy: 1e-9,
      "減衰区間は a から d まで＝長さ d - a")
    XCTAssertNotEqual(
      param.value(at: duration / 2), (gain * AudioParam.zero).squareRoot(), accuracy: 1e-6,
      "区間長を d と取り違えたときの中点とは一致しない")
  }

  /// 立ち上がりの中点も幾何平均（[0, a] の指数）。
  func testExponentialRampIsGeometricWithinAttack() {
    var param = AudioParam(AudioParam.zero, at: 0)
    param.rampExponentially(to: 0.15, at: 0.004)
    XCTAssertEqual(
      param.value(at: 0.002), (0.15 * AudioParam.zero).squareRoot(), accuracy: 1e-9)
  }

  /// `setValueAtTime` は次のイベントが撃たれるまで平坦（glide の 4 イベントのゲインがこの形）。
  func testSetValueHoldsUntilNextEvent() {
    let gain = 0.12
    let duration = 0.4
    var param = AudioParam(AudioParam.zero, at: 0)
    param.rampExponentially(to: gain, at: 0.02)
    param.setValue(gain, at: duration * 0.7)
    param.rampExponentially(to: AudioParam.zero, at: duration + 0.15)

    XCTAssertEqual(param.value(at: 0.02), gain, accuracy: 1e-12)
    XCTAssertEqual(param.value(at: 0.15), gain, accuracy: 1e-12, "0.02〜0.7d は平坦")
    XCTAssertEqual(param.value(at: duration * 0.7), gain, accuracy: 1e-12)
    // 減衰区間は 0.7d から d+0.15 まで＝長さ 0.3d + 0.15。
    let middle = (duration * 0.7 + duration + 0.15) / 2
    XCTAssertEqual(
      param.value(at: middle), (gain * AudioParam.zero).squareRoot(), accuracy: 1e-9)
  }

  // MARK: - 帯域制限（Nyquist 超の倍音を足さない）

  /// 3 倍音が Nyquist を超える高い音では基音だけになる（＝素の級数のエイリアスが乗らない）。
  func testBandLimitedWaveformsDropHarmonicsAboveNyquist() {
    let phase = 0.7
    let square = Waveform.square.sample(phase: phase, frequency: 9000, sampleRate: 48000)
    XCTAssertEqual(square, 4 / Double.pi * sin(phase), accuracy: 1e-12, "矩形波は基音のみ")
    let triangle = Waveform.triangle.sample(phase: phase, frequency: 9000, sampleRate: 48000)
    XCTAssertEqual(triangle, 8 / (Double.pi * Double.pi) * sin(phase), accuracy: 1e-12)
  }

  /// 境界は `k * f < Nyquist`（等号は足さない）。f=8000 は 3 倍音が丁度 Nyquist なので基音のみ、
  /// f=7000 は 3 倍音が入る。
  func testHarmonicCountBoundaryIsStrictlyBelowNyquist() {
    let phase = 1.1
    XCTAssertEqual(
      Waveform.square.sample(phase: phase, frequency: 8000, sampleRate: 48000),
      4 / Double.pi * sin(phase), accuracy: 1e-12, "3f == Nyquist は足さない")
    XCTAssertEqual(
      Waveform.square.sample(phase: phase, frequency: 7000, sampleRate: 48000),
      4 / Double.pi * (sin(phase) + sin(3 * phase) / 3), accuracy: 1e-12, "3f < Nyquist は足す")
  }

  /// sine は倍音を持たない（帯域制限の分岐に巻き込まれない）。
  func testSineIsPlainSine() {
    XCTAssertEqual(
      Waveform.sine.sample(phase: 2.3, frequency: 100, sampleRate: 48000), sin(2.3),
      accuracy: 1e-12)
  }

  // MARK: - Biquad（lowpass/highpass の Q は dB・bandpass は線形）

  /// RBJ Cookbook のリファレンス値（f0=1000・Fs=48000）。取り違えを数値で固定する。
  func testBiquadReferenceCoefficients() {
    assertCoefficients(
      Biquad.coefficients(kind: .lowpass, frequency: 1000, q: 1, sampleRate: 48000),
      [0.0040424377, 0.0080848754, 0.0040424377, -1.8738932320, 0.8900629828])
    assertCoefficients(
      Biquad.coefficients(kind: .highpass, frequency: 1000, q: 0.5, sampleRate: 48000),
      [0.9379341189, -1.8758682378, 0.9379341189, -1.8678096100, 0.8839268655])
    assertCoefficients(
      Biquad.coefficients(kind: .bandpass, frequency: 1000, q: 1, sampleRate: 48000),
      [0.0612647677, 0, -0.0612647677, -1.8614084445, 0.8774704646])
  }

  /// Q の解釈が種別で違うことそのものを固定する: lowpass の Q は dB なので `q = 20`（dB）と
  /// bandpass の `q = 10`（線形）が同じ α になり、分母（a1・a2）が一致する。取り違えると崩れる。
  func testLowpassQIsDecibelsWhileBandpassQIsLinear() {
    let lowpass = Biquad.coefficients(kind: .lowpass, frequency: 1200, q: 20, sampleRate: 44100)
    let bandpass = Biquad.coefficients(kind: .bandpass, frequency: 1200, q: 10, sampleRate: 44100)
    XCTAssertEqual(lowpass.a1, bandpass.a1, accuracy: 1e-12)
    XCTAssertEqual(lowpass.a2, bandpass.a2, accuracy: 1e-12)
    let linear = Biquad.coefficients(kind: .lowpass, frequency: 1200, q: 10, sampleRate: 44100)
    XCTAssertNotEqual(linear.a2, bandpass.a2, accuracy: 1e-6, "dB を線形として読むと別物になる")
  }

  /// lowpass は DC で利得 1、highpass は Nyquist で利得 1（係数の正規化が正しいことの検算）。
  func testFilterGainAtPassbandEdges() {
    let lowpass = Biquad.coefficients(kind: .lowpass, frequency: 3500, q: 1, sampleRate: 48000)
    XCTAssertEqual(
      (lowpass.b0 + lowpass.b1 + lowpass.b2) / (1 + lowpass.a1 + lowpass.a2), 1, accuracy: 1e-9)
    let highpass = Biquad.coefficients(kind: .highpass, frequency: 2500, q: 0.5, sampleRate: 48000)
    XCTAssertEqual(
      (highpass.b0 - highpass.b1 + highpass.b2) / (1 - highpass.a1 + highpass.a2), 1,
      accuracy: 1e-9)
  }

  // MARK: - 白色雑音（固定シードで決定論）

  func testWhiteNoiseIsDeterministicAndInRange() {
    var a = WhiteNoise(seed: 12345)
    var b = WhiteNoise(seed: 12345)
    var c = WhiteNoise(seed: 999)
    var sameCount = 0
    for _ in 0..<2000 {
      let sample = a.next()
      XCTAssertEqual(sample, b.next(), "同じシードは同じ列")
      XCTAssertGreaterThanOrEqual(sample, -1)
      XCTAssertLessThan(sample, 1)
      if sample == c.next() { sameCount += 1 }
    }
    XCTAssertEqual(sameCount, 0, "別シードは別の列")
  }

  // MARK: - コンプレッサの静特性（ニーの内外 3 領域）

  func testCompressorStaticCurveRegions() {
    // threshold（-24）までは素通し——ニーを threshold の中央に置くと -39 dB から潰れ始める。
    XCTAssertEqual(DynamicsCompressor.curve(inputDB: -60), -60, accuracy: 1e-12)
    XCTAssertEqual(DynamicsCompressor.curve(inputDB: -24), -24, accuracy: 1e-12)
    // ニーの中（-24 〜 +6）は二次で滑らかに折れる。
    XCTAssertEqual(DynamicsCompressor.curve(inputDB: -9), -12.4375, accuracy: 1e-9)
    // ニーの上（+6 超）は比 12:1。
    XCTAssertEqual(DynamicsCompressor.curve(inputDB: 18), -6.75, accuracy: 1e-9)
  }

  /// ニーの両端で値も傾きも連続（折れ目に段差が出ない・上端で傾きが 1/ratio になる）。
  func testCompressorCurveIsContinuousAtKneeEdges() {
    let lower = DynamicsCompressor.threshold
    let upper = DynamicsCompressor.kneeEnd
    XCTAssertEqual(DynamicsCompressor.curve(inputDB: lower), lower, accuracy: 1e-9)
    let d = 1e-6
    XCTAssertEqual(
      (DynamicsCompressor.curve(inputDB: upper + d) - DynamicsCompressor.curve(inputDB: upper - d))
        / (2 * d), 1 / DynamicsCompressor.ratio, accuracy: 1e-6, "ニー上端で傾きが比へ繋がる")
  }

  /// メイクアップゲインは静特性から導く（仕様の "Computing the makeup gain"）。定数を焼かない。
  func testMakeupGainIsDerivedFromTheCurve() {
    XCTAssertEqual(
      DynamicsCompressor.makeupGain,
      pow(pow(10, DynamicsCompressor.curve(inputDB: 0) / 20), -0.6), accuracy: 1e-12)
    XCTAssertGreaterThan(DynamicsCompressor.makeupGain, 1, "圧縮で落ちた分を持ち上げる")
  }

  /// 閾値以下の信号はメイクアップぶんだけ持ち上がり（圧縮はされない）、大きな信号は押さえ込む。
  func testCompressorLiftsQuietSignalAndTamesLoudOne() {
    var quiet = [Double](repeating: 0.01, count: 4800)  // -40 dB＝threshold 以下
    DynamicsCompressor.apply(to: &quiet, sampleRate: 48000)
    XCTAssertEqual(quiet.last!, 0.01 * DynamicsCompressor.makeupGain, accuracy: 1e-6)
    var loud = [Double](repeating: 0.9, count: 4800)
    DynamicsCompressor.apply(to: &loud, sampleRate: 48000)
    XCTAssertLessThan(
      loud.last! / quiet.last!, 45, "入力の 90 倍差が半分以下へ詰まる＝実際に圧縮している")
  }

  /// 期待値は `[b0, b1, b2, a1, a2]`（a0 で正規化済み）。
  private func assertCoefficients(
    _ c: Biquad.Coefficients, _ expected: [Double],
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      [c.b0, c.b1, c.b2, c.a1, c.a2].count, expected.count, file: file, line: line)
    for (actual, want) in zip([c.b0, c.b1, c.b2, c.a1, c.a2], expected) {
      XCTAssertEqual(actual, want, accuracy: 1e-9, file: file, line: line)
    }
  }
}
