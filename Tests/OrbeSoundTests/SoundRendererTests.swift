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

  // MARK: - 観測ヘルパ（時変周波数はゼロ交差から推定する。量子化誤差 ±1/(2W)・振幅と波形に非依存）

  private func zeroCrossings(_ samples: [Float], in range: Range<Int>) -> Int {
    var count = 0
    for i in range.dropFirst() where (samples[i - 1] < 0) != (samples[i] < 0) { count += 1 }
    return count
  }

  private func estimatedFrequency(of samples: [Float], from: Double, to: Double) -> Double {
    let range = Int(from * sampleRate)..<min(samples.count, Int(to * sampleRate))
    return Double(zeroCrossings(samples, in: range)) / (2 * (to - from))
  }

  private func peaks(of samples: ArraySlice<Float>, count: Int = 8) -> [SoundAnalysis.SpectralPeak]
  {
    SoundAnalysis.spectralPeaks(Array(samples), sampleRate: sampleRate, count: count)
  }

  // MARK: - glide（周波数軌道）

  private func glide(from: Double, to: Double, detuneCents: Double = 0, overshoot: Double? = nil)
    -> SoundProgram
  {
    SoundProgram(components: [
      .glide(
        GlideSpec(
          from: from, to: to, detuneCents: detuneCents, start: 0, duration: 0.4, gain: 0.2,
          overshoot: overshoot))
    ])
  }

  /// glide は from の音程で始まり、duration で to へ到達する。
  func testGlideMovesFromStartFrequencyToTarget() {
    let samples = render(glide(from: 300, to: 900))
    XCTAssertEqual(estimatedFrequency(of: samples, from: 0, to: 0.02), 300, accuracy: 30)
    XCTAssertEqual(estimatedFrequency(of: samples, from: 0.40, to: 0.45), 900, accuracy: 15)
  }

  /// overshoot は 0.6d の経由点で to を超えてから to へ落ち着く（弾みの跳ね上がり）。
  func testGlideOvershootRisesAboveTheTargetBeforeSettling() {
    let samples = render(glide(from: 300, to: 900, overshoot: 1.5))
    XCTAssertGreaterThan(
      estimatedFrequency(of: samples, from: 0.22, to: 0.26), 1000, "経由点で to を超える")
    XCTAssertEqual(
      estimatedFrequency(of: samples, from: 0.40, to: 0.45), 900, accuracy: 15, "最後は to へ落ち着く")
  }

  /// detuneCents は軌道全体（from も to も）へ周波数比として掛かる。
  func testGlideDetuneScalesTheWholeTrajectory() {
    let base = render(glide(from: 300, to: 900))
    let detuned = render(glide(from: 300, to: 900, detuneCents: 200))
    let ratio =
      Double(zeroCrossings(detuned, in: detuned.indices))
      / Double(zeroCrossings(base, in: base.indices))
    XCTAssertEqual(ratio, pow(2, 200.0 / 1200), accuracy: 0.01)
  }

  // MARK: - FM（側波帯は f ± n·f·ratio。負の位置は 0 Hz で折り返す）

  private func fm(index: Envelope, duration: Double = 0.5) -> SoundProgram {
    SoundProgram(components: [
      .fm(FMSpec(frequency: 440, start: 0, duration: duration, ratio: 2, index: index, gain: 0.2))
    ])
  }

  /// 実効変調指数 β = index/ratio ≈ 0 の FM はキャリア純音（側波帯が立たない）。
  func testFMWithNearZeroIndexIsAPureCarrier() {
    let found = SoundAnalysis.spectralPeaks(
      render(fm(index: .constant(0))), sampleRate: sampleRate, count: 5)
    XCTAssertFalse(found.isEmpty)
    for peak in found {
      XCTAssertEqual(peak.frequency, 440, accuracy: 50, "キャリア以外のピーク: \(found)")
    }
  }

  /// index を上げると上側波帯 f + f·ratio が立つ（金属質の倍音の正体）。
  func testFMIndexRaisesTheUpperSideband() {
    let found = SoundAnalysis.spectralPeaks(
      render(fm(index: .constant(2))), sampleRate: sampleRate, count: 5)
    let resolution = sampleRate / 4096
    XCTAssertTrue(
      found.contains { abs($0.frequency - 1320) < resolution + 5 && $0.levelDB > -10 },
      "上側波帯 1320 Hz が立たない: \(found)")
  }

  /// index 減衰形では立ち上がりだけ側波帯が濃く、終端はキャリアのみへ収束する
  /// （steel の「立ち上がりだけ倍音が濃い金属打音」の根拠）。
  func testFMIndexEnvelopeFadesTheSidebandsOverTime() {
    let samples = render(fm(index: .sweep(from: 5, to: 0.02, endFraction: 0.35), duration: 1.0))
    let window = 4096
    func sidebandLevel(_ peaks: [SoundAnalysis.SpectralPeak]) -> Double {
      peaks.filter { abs($0.frequency - 1320) < 30 }.map(\.levelDB).max() ?? -60
    }
    let head = sidebandLevel(peaks(of: samples[0..<window]))
    let tailStart = Int(1.0 * sampleRate) - window
    let tail = sidebandLevel(peaks(of: samples[tailStart..<(tailStart + window)]))
    XCTAssertGreaterThan(head, -20, "前半窓に側波帯が立たない")
    XCTAssertLessThan(tail, -40, "終端窓で側波帯が消えない")
  }

  // MARK: - tone lowpass / noise cutoff

  /// tone の lowpass はカットオフ超の倍音を減衰させる（arcade・demo の角の丸めが頼る配線）。
  func testToneLowpassAttenuatesHarmonicsAboveTheCutoff() {
    func harmonicLevel(lowpass: Double?) -> Double {
      let program = SoundProgram(components: [
        .tone(
          ToneSpec(
            frequency: 500, start: 0, duration: 0.4, waveform: .sawtooth, gain: 0.2,
            envelope: .gate(attack: 0.01, sustainFraction: 0.9, release: 0.05), lowpass: lowpass))
      ])
      let samples = render(program)
      return peaks(of: samples[...]).filter { abs($0.frequency - 2000) < 30 }
        .map(\.levelDB).max() ?? -60
    }
    let open = harmonicLevel(lowpass: nil)
    XCTAssertGreaterThan(open, -16, "フィルタ無しでは第 4 倍音が立つ")
    XCTAssertLessThan(harmonicLevel(lowpass: 1000), open - 8, "lowpass で大きく落ちる")
  }

  /// bandpass + cutoff sweep は帯域中心を時間で上へ動かす（ゼロ交差率の順序で観測する
  /// ——支配的スペクトルピークは雑音 1 実現の当たり外れで逆転し得るため、値は主張しない）。
  func testNoiseCutoffSweepRaisesTheBandOverTime() {
    let program = SoundProgram(components: [
      .noise(
        NoiseSpec(
          start: 0, duration: 0.6, gain: 0.3, kind: .bandpass,
          cutoff: .sweep(from: 500, to: 4000), q: 2,
          envelope: .gate(attack: 0.01, sustainFraction: 0.95, release: 0.05)))
    ])
    let samples = render(program)
    let head = zeroCrossings(samples, in: 0..<Int(0.1 * sampleRate))
    let tail = zeroCrossings(samples, in: Int(0.5 * sampleRate)..<Int(0.6 * sampleRate))
    XCTAssertGreaterThan(tail, head, "後半窓のゼロ交差率が上がらない")
  }

  /// 値が動かない cutoff は、固定係数経路でも毎サンプル係数を組む経路でも同じ音になる
  /// （constantValue 最適化が音を変えないこと。全点同値の列も固定経路に入るため、
  /// 可変経路は「聴感上同値だが値が異なる」sweep で踏む）。
  func testConstantCutoffMatchesThePerSampleCoefficientPath() {
    func rendered(cutoff: Envelope) -> [Float] {
      SoundRenderer.render(
        program: SoundProgram(components: [
          .noise(NoiseSpec(start: 0, duration: 0.3, gain: 0.3, kind: .bandpass, cutoff: cutoff))
        ]), volume: 70, sampleRate: sampleRate, seedKey: "same")
    }
    let fixed = rendered(cutoff: .constant(1200))
    let variable = rendered(cutoff: .sweep(from: 1200, to: 1200 * (1 + 1e-10)))
    XCTAssertEqual(fixed.count, variable.count)
    let maxDiff = zip(fixed, variable).map { abs(Double($0) - Double($1)) }.max() ?? .infinity
    XCTAssertLessThan(maxDiff, 1e-6)
  }

  /// 同一仕様の noise 部品どうしは別々の雑音列になる（部品インデックスがシードに混ざる）。
  /// 無相関なら 2 本の重なりは +3 dB、同一列に退行すると +6 dB になり質感も変わる。
  func testIdenticalNoiseComponentsGetIndependentNoise() {
    func rms(componentCount: Int) -> Double {
      let spec = NoiseSpec(
        start: 0, duration: 0.3, gain: 0.1, kind: .bandpass, cutoff: .constant(1200))
      let program = SoundProgram(
        components: Array(repeating: SoundComponent.noise(spec), count: componentCount))
      // コンプレッサの非線形が加算則を歪めないよう、threshold の遥か下の小音量で測る。
      return SoundAnalysis.rmsDB(
        SoundRenderer.render(program: program, volume: 5, sampleRate: sampleRate, seedKey: "mix"))
    }
    XCTAssertEqual(rms(componentCount: 2) - rms(componentCount: 1), 3.01, accuracy: 1.0)
  }

  // MARK: - pitchLFO

  /// pitchLFO は瞬時周波数を depth（Hz）幅で山谷に揺らす（reply / whistle のビブラート）。
  /// LFO 位相は 0 起点なので山 = 1/(4·rate)、谷 = 3/(4·rate)。
  func testPitchLFOSwingsTheInstantFrequencyByDepth() {
    func program(lfo: LFO?) -> SoundProgram {
      SoundProgram(components: [
        .tone(
          ToneSpec(
            frequency: 1000, start: 0, duration: 0.4, gain: 0.2,
            envelope: .gate(attack: 0.01, sustainFraction: 0.9, release: 0.05), pitchLFO: lfo))
      ])
    }
    let still = render(program(lfo: nil))
    XCTAssertEqual(estimatedFrequency(of: still, from: 0.04, to: 0.06), 1000, accuracy: 30)
    XCTAssertEqual(estimatedFrequency(of: still, from: 0.14, to: 0.16), 1000, accuracy: 30)
    let vibrato = render(program(lfo: LFO(rate: 5, depth: 100)))
    XCTAssertGreaterThan(estimatedFrequency(of: vibrato, from: 0.04, to: 0.06), 1050, "山窓")
    XCTAssertLessThan(estimatedFrequency(of: vibrato, from: 0.14, to: 0.16), 950, "谷窓")
  }

  // MARK: - 境界（duration は打ち切りの契約）

  /// duration が部品より短ければその長さで打ち切られ、duration 以降に始まる部品は書かれない。
  func testProgramDurationTruncatesAndExcludesOutOfRangeComponents() {
    let truncated = render(
      SoundProgram(
        components: [.tone(ToneSpec(frequency: 700, start: 0, duration: 0.5, gain: 0.2))],
        duration: 0.1))
    XCTAssertEqual(truncated.count, Int((0.1 * sampleRate).rounded(.up)))
    XCTAssertGreaterThan(truncated.map(abs).max() ?? 0, 0, "打ち切りまでは鳴る")
    let silent = render(
      SoundProgram(
        components: [.tone(ToneSpec(frequency: 700, start: 0.5, duration: 0.2, gain: 0.2))],
        duration: 0.5))
    XCTAssertEqual(silent.map(abs).max(), 0, "範囲外の部品は 1 サンプルも書かない")
  }

  /// duration 0 は部品の有無を問わず 1 フレームの無音（frameCount の下限）。
  func testZeroDurationYieldsASingleSilentFrame() {
    XCTAssertEqual(render(SoundProgram(components: [])), [0])
    XCTAssertEqual(
      render(
        SoundProgram(
          components: [.tone(ToneSpec(frequency: 700, start: 0, duration: 0.2, gain: 0.2))],
          duration: 0)), [0])
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

  // MARK: - 音量 → 合成ゲインのマッピング

  /// 両端は設計どおりの値に厳密に落ちる: 5% で 0.05（-26.02 dB）、100% で 1.0（0 dB）。
  /// ここが動くと最小音量と最大音量の聞こえ方そのものが変わる。
  func testVolumeMappingPinsBothEnds() {
    XCTAssertEqual(SoundRenderer.level(forVolume: 5), 0.05, accuracy: 1e-12)
    XCTAssertEqual(SoundRenderer.level(forVolume: 100), 1.0, accuracy: 1e-12)
  }

  /// 1 ステップ（5%）はどの音量域でも同じ 1.3695 dB 効く。% を線形の係数にすると 1 ステップの効きが
  /// 音量域で 15 倍違い、上端は弁別閾（約 1 dB）を割って押しても変わらないステップになる
  /// ——その退行をここで撃ち落とす。
  func testVolumeMappingIsEvenlySpacedInDecibels() {
    for volume in stride(from: 5, through: 95, by: 5) {
      let step =
        20
        * log10(SoundRenderer.level(forVolume: volume + 5) / SoundRenderer.level(forVolume: volume))
      XCTAssertEqual(step, 1.3695, accuracy: 1e-4, "\(volume)→\(volume + 5)% の効きが等間隔でない")
    }
  }

  /// 音量を上げれば必ず大きくなる。
  func testVolumeMappingIsMonotonic() {
    for volume in stride(from: 5, through: 95, by: 5) {
      XCTAssertGreaterThan(
        SoundRenderer.level(forVolume: volume + 5), SoundRenderer.level(forVolume: volume))
    }
  }

  // MARK: - マスタ末尾（合成音と取り込み済み音源が共有する 1 本）

  /// 括り出した `finalize` は長さを変えず決定論（案の合成と同じ性質を、取り込み済み音源にも与える）。
  /// 括り出しが 24 音の出力を 1 サンプルも変えていないことは、既存の決定論・ラウドネス整合・
  /// 「音量はコンプレッサの手前」の 3 つの釘（`SoundCatalogTests`）が引き続き押さえている。
  func testFinalizeIsLengthPreservingAndDeterministic() {
    let samples = (0..<Int(0.3 * sampleRate)).map {
      Float(0.4 * sin(2 * Double.pi * 523 * Double($0) / sampleRate))
    }
    let first = SoundRenderer.finalize(samples, volume: 70, sampleRate: sampleRate)
    XCTAssertEqual(first.count, samples.count)
    XCTAssertEqual(first, SoundRenderer.finalize(samples, volume: 70, sampleRate: sampleRate))
  }

  /// finalize でも音量はコンプレッサの手前に掛かる（下げると圧縮が浅くなる）。
  /// 取り込み済み音源が「素通しゲインで小さくなるだけ」の鳴り方に退行したらここで落ちる。
  func testFinalizeAppliesVolumeBeforeTheCompressor() {
    let samples = (0..<Int(0.5 * sampleRate)).map {
      Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / sampleRate))
    }
    let loud = SoundRenderer.finalize(samples, volume: 100, sampleRate: sampleRate)
    let quiet = SoundRenderer.finalize(samples, volume: 20, sampleRate: sampleRate)
    let loudPeak = loud.map { abs($0) }.max() ?? 0
    let quietPeak = quiet.map { abs($0) }.max() ?? 0
    let ratio = Float(SoundRenderer.level(forVolume: 20))
    XCTAssertLessThan(quietPeak, loudPeak)
    XCTAssertGreaterThan(quietPeak, loudPeak * ratio * 1.02, "コンプレッサの後段なら厳密にこの比になる")
  }
}
