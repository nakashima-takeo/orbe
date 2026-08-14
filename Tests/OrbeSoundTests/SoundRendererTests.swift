import XCTest

@testable import OrbeSound

/// 新語彙（sawtooth / detune / LFO / delay / SoundProgram）がレンダリング結果に約束どおり
/// 現れることの性質検証。ここが崩れると、語彙で書いた意図と鳴る音が食い違う。
final class SoundRendererTests: XCTestCase {
  private let sampleRate = 48000.0

  private func render(_ program: SoundProgram, volume: Int = 70) -> [Float] {
    SoundRenderer.render(
      program: program, volume: volume, sampleRate: sampleRate, seedKey: "test")
  }

  private func tone(
    _ frequency: Double, waveform: Waveform = .sine, detuneCents: Double = 0, gainLFO: LFO? = nil
  ) -> SoundProgram {
    SoundProgram(components: [
      .tone(
        ToneSpec(
          frequency: frequency, detuneCents: detuneCents, start: 0, duration: 0.4,
          waveform: waveform, gain: 0.2,
          envelope: .gate(attack: 0.01, sustainFraction: 0.9, release: 0.05), gainLFO: gainLFO))
    ])
  }

  /// sawtooth には偶数次倍音が立つ（奇数次のみの triangle との聴感差の根拠）。
  func testSawtoothHasEvenHarmonicsWhileTriangleDoesNot() {
    let resolution = sampleRate / 4096
    let saw = SoundAnalysis.spectralPeaks(
      render(tone(500, waveform: .sawtooth)), sampleRate: sampleRate, count: 5)
    XCTAssertTrue(
      saw.contains { abs($0.frequency - 1000) < resolution && $0.levelDB > -30 },
      "sawtooth の第 2 倍音が立たない: \(saw)")
    let triangle = SoundAnalysis.spectralPeaks(
      render(tone(500, waveform: .triangle)), sampleRate: sampleRate, count: 5)
    XCTAssertFalse(
      triangle.contains { abs($0.frequency - 1000) < resolution && $0.levelDB > -30 },
      "triangle に第 2 倍音が立ってしまう: \(triangle)")
  }

  /// detune はスペクトルピークをセントどおりに動かす（+200 セント = ×2^(1/6)）。
  func testDetuneShiftsTheSpectralPeak() {
    let detuned = SoundAnalysis.spectralPeaks(
      render(tone(1000, detuneCents: 200)), sampleRate: sampleRate, count: 1)
    let expected = 1000 * pow(2, 200.0 / 1200)
    XCTAssertEqual(
      detuned.first?.frequency ?? 0, expected, accuracy: sampleRate / 4096 + 1)
  }

  /// gainLFO は振幅を rate の周期で揺らす（谷では深さぶん沈み、山では公称のまま）。
  func testGainLFOModulatesAmplitudeAtItsRate() {
    // rate 5 Hz: t=0.05 が山（sine の 1/4 周期）、t=0.15 が谷（3/4 周期）。depth 1 で谷は無音。
    let samples = render(tone(1000, gainLFO: LFO(rate: 5, depth: 1)))
    func windowRMS(_ center: Double) -> Double {
      let range = Int((center - 0.01) * sampleRate)..<Int((center + 0.01) * sampleRate)
      let sum = samples[range].reduce(0.0) { $0 + Double($1) * Double($1) }
      return (sum / Double(range.count)).squareRoot()
    }
    let crest = windowRMS(0.05)
    let trough = windowRMS(0.15)
    XCTAssertGreaterThan(crest, 0.01, "山では鳴っている")
    XCTAssertLessThan(trough, crest * 0.1, "谷では深さぶん沈む")
  }

  /// delay のテールは部品の発音が終わった後のバッファに現れ、program の duration まで書かれる。
  func testDelayTailSoundsBeyondTheComponents() {
    let dry = SoundProgram(components: [
      .tone(ToneSpec(frequency: 800, start: 0, duration: 0.1, gain: 0.2))
    ])
    let wet = SoundProgram(
      components: dry.components,
      effects: [.delay(time: 0.3, feedback: 0.5, damping: 6000, mix: 0.8)],
      duration: 1.2)
    let samples = render(wet)
    XCTAssertEqual(samples.count, Int((1.2 * sampleRate).rounded(.up)), "テール込みの全長で書く")
    // 部品は 0.2 秒までに鳴り終わる。0.3 秒以降にディレイの繰り返しだけが残る。
    let tail = samples[Int(0.3 * sampleRate)...]
    XCTAssertGreaterThan(tail.map(abs).max() ?? 0, 0.005, "テールが鳴っている")
    let dryTail = render(dry)
    XCTAssertEqual(
      Double(dryTail.count) / sampleRate, dry.duration, accuracy: 0.001,
      "エフェクト無しの全長は部品の発音終了まで")
  }

  /// program のレンダリングも決定論（ノイズ部品は seedKey で固定される）。
  func testProgramRenderIsDeterministic() {
    let program = SoundProgram(
      components: [
        .noise(
          NoiseSpec(
            start: 0, duration: 0.3, gain: 0.2, kind: .bandpass, cutoff: .sweep(from: 800, to: 2000)
          ))
      ],
      effects: [.delay(time: 0.1, feedback: 0.3, damping: 4000, mix: 0.5)],
      duration: 0.8)
    let first = SoundRenderer.render(
      program: program, volume: 70, sampleRate: sampleRate, seedKey: "same")
    let second = SoundRenderer.render(
      program: program, volume: 70, sampleRate: sampleRate, seedKey: "same")
    XCTAssertEqual(first, second, "同一入力・同一 seedKey は同一波形")
    let other = SoundRenderer.render(
      program: program, volume: 70, sampleRate: sampleRate, seedKey: "different")
    XCTAssertNotEqual(first, other, "seedKey が違えばノイズ列も違う")
  }
}
