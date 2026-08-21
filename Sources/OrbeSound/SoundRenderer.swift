import Foundation

/// `SoundProgram`（部品列 + エフェクト列 + 全長）から決定論的にモノラル PCM を組む。
///
/// マスタチェーンは 全部品を加算 → × トリム → エフェクト列 → × 音量 → コンプレッサ の順。
/// **音量がコンプレッサの手前**にあるのが要点で、音量を上げるほど圧縮が深くなる（＝音量は再生側の
/// ボリュームではなく合成の入力）。事前生成した音声ファイルを同梱するとこの順が崩れる。
public enum SoundRenderer {
  /// 既定音量（%）。アプリの設定既定・dev CLI の `--volume` 既定・`SoundCatalog` のトリムを測る点は
  /// 同じ 1 つ——別々のリテラルに写すと、CLI で測った読みがアプリの鳴りとずれてトリムが狂う。
  public static let defaultVolume = 90

  /// 音量の下限（5）と、そこでのゲイン（0.05 = -26.02 dB）。上限 100 のゲイン 1.0（0 dB）との間を
  /// dB で等分する。値域 5...100 は設定の読み込み時クランプと CLI の `--volume` 検証が保証する
  /// ——ここで二重に守ると値域の持ち主が二人になる。
  private static let minVolume = 5.0
  private static let minLevel = 0.05

  /// 音量 % → 合成ゲイン（線形係数）。dB 等間隔で、1 ステップ（5%）が全域で 1.3695 dB 効く
  /// ——% をそのまま係数にすると 1 ステップの効きが音量域で 15 倍違い、上端は弁別閾（約 1 dB）を
  /// 割って押しても変わらないステップになる。音量を掛ける経路はすべてここを通る。
  public static func level(forVolume volume: Int) -> Double {
    pow(minLevel, (100 - Double(volume)) / (100 - minVolume))
  }

  /// カタログの案 × イベントを合成する（アプリの再生層が使う口）。
  /// 音量は % で受け、`level(forVolume:)` で合成ゲインへ写す（設定が渡すのは 5〜100）。
  public static func render(
    family: NotificationSound, event: AgentSoundEvent, volume: Int, sampleRate: Double
  ) -> [Float] {
    render(
      program: SoundCatalog.program(family, event), volume: volume, sampleRate: sampleRate,
      seedKey: "\(family.rawValue)/\(event.rawValue)")
  }

  /// 任意の program を合成する（scratch・カタログ共通の本体）。`seedKey` はノイズ部品の
  /// 決定論シードの素——同じ program・同じ key なら常に同じ波形になる。
  public static func render(
    program: SoundProgram, volume: Int, sampleRate: Double, seedKey: String
  ) -> [Float] {
    let frameCount = max(1, Int((program.duration * sampleRate).rounded(.up)))
    var buffer = [Double](repeating: 0, count: frameCount)

    for (index, component) in program.components.enumerated() {
      switch component {
      case .tone(let spec): renderTone(spec, into: &buffer, sampleRate: sampleRate)
      case .glide(let spec): renderGlide(spec, into: &buffer, sampleRate: sampleRate)
      case .fm(let spec): renderFM(spec, into: &buffer, sampleRate: sampleRate)
      case .noise(let spec):
        renderNoise(
          spec, into: &buffer, sampleRate: sampleRate, seed: noiseSeed(key: seedKey, index: index))
      }
    }

    if program.trimDB != 0 {
      let trim = pow(10, program.trimDB / 20)
      for i in buffer.indices { buffer[i] *= trim }
    }
    for effect in program.effects { effect.apply(to: &buffer, sampleRate: sampleRate) }

    finalize(&buffer, volume: volume, sampleRate: sampleRate)
    return buffer.map { Float($0) }
  }

  /// マスタチェーンの末尾（× 音量ゲイン → コンプレッサ）。合成音と取り込み済みのカスタム音源は
  /// **この 1 本を共有する**——案とカスタムを切り替えても聴感の強さと音量ノブの手応え
  /// （下げると圧縮が浅くなる挙動を含む）が揃うのは、末尾が同じ 1 実装であることに拠る。
  public static func finalize(_ samples: [Float], volume: Int, sampleRate: Double) -> [Float] {
    var buffer = samples.map { Double($0) }
    finalize(&buffer, volume: volume, sampleRate: sampleRate)
    return buffer.map { Float($0) }
  }

  private static func finalize(_ buffer: inout [Double], volume: Int, sampleRate: Double) {
    let level = Self.level(forVolume: volume)
    for i in buffer.indices { buffer[i] *= level }
    DynamicsCompressor.apply(to: &buffer, sampleRate: sampleRate)
  }

  /// 部品ごとに違う（が毎回同じ）ノイズ列を出すためのシード。Swift の `Hasher` はプロセスごとに
  /// 種が変わるので使えない——決定論が崩れるとテストが再現しない。
  private static func noiseSeed(key: String, index: Int) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in key.utf8 {
      hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
    }
    return (hash ^ UInt64(index &+ 1)) &* 0x100_0000_01b3
  }

  /// 部品が buffer に書き込むフレーム範囲。
  private static func frames(
    from start: Double, to end: Double, rate: Double, count: Int
  ) -> Range<Int> {
    let first = max(0, Int(start * rate))
    let last = min(count, Int((end * rate).rounded(.up)))
    return first < last ? first..<last : 0..<0
  }

  /// デチューン（セント）を周波数比へ。
  private static func detuneRatio(_ cents: Double) -> Double { pow(2, cents / 1200) }

  private static func renderTone(_ s: ToneSpec, into buffer: inout [Double], sampleRate: Double) {
    let gain = s.envelope.automation(start: s.start, duration: s.duration, scale: s.gain)
    // 瞬時周波数は 1 Hz 以上（0 以下だと帯域制限の倍音ループが終わらない）。glide と同じ不変条件。
    let frequency = max(s.frequency * detuneRatio(s.detuneCents), 1)
    let coefficients = s.lowpass.map {
      Biquad.coefficients(kind: .lowpass, frequency: $0, q: 1, sampleRate: sampleRate)
    }
    var filter = Biquad()
    var phase = 0.0
    for i in frames(from: s.start, to: s.end, rate: sampleRate, count: buffer.count) {
      let t = Double(i) / sampleRate
      var instant = frequency
      if let lfo = s.pitchLFO { instant = max(instant + lfo.depth * lfo.value(at: t - s.start), 1) }
      var sample =
        s.waveform.sample(phase: phase, frequency: instant, sampleRate: sampleRate)
        * gain.value(at: t)
      if let lfo = s.gainLFO { sample *= lfo.gainMultiplier(at: t - s.start) }
      if let coefficients { sample = filter.process(sample, coefficients) }
      buffer[i] += sample
      phase += 2 * Double.pi * instant / sampleRate
    }
  }

  private static func renderGlide(_ s: GlideSpec, into buffer: inout [Double], sampleRate: Double) {
    let ratio = detuneRatio(s.detuneCents)
    var frequency = AudioParam(s.from * ratio, at: s.start)
    if let overshoot = s.overshoot {
      frequency.rampExponentially(to: s.to * ratio * overshoot, at: s.start + s.duration * 0.6)
    }
    frequency.rampExponentially(to: s.to * ratio, at: s.start + s.duration)
    let gain = s.envelope.automation(start: s.start, duration: s.duration, scale: s.gain)

    var phase = 0.0
    for i in frames(from: s.start, to: s.end, rate: sampleRate, count: buffer.count) {
      let t = Double(i) / sampleRate
      var instant = frequency.value(at: t)
      if let lfo = s.pitchLFO { instant += lfo.depth * lfo.value(at: t - s.start) }
      instant = max(instant, 1)
      var sample =
        s.waveform.sample(phase: phase, frequency: instant, sampleRate: sampleRate)
        * gain.value(at: t)
      if let lfo = s.gainLFO { sample *= lfo.gainMultiplier(at: t - s.start) }
      buffer[i] += sample
      phase += 2 * Double.pi * instant / sampleRate
    }
  }

  private static func renderFM(_ s: FMSpec, into buffer: inout [Double], sampleRate: Double) {
    // インデックスのエンベロープはインデックスそのもの（周波数偏移は f * index(t)）。
    let index = s.index.automation(start: s.start, duration: s.duration)
    let gain = s.envelope.automation(start: s.start, duration: s.duration, scale: s.gain)

    var carrierPhase = 0.0
    var modulatorPhase = 0.0
    let modulatorStep = 2 * Double.pi * s.frequency * s.ratio / sampleRate
    for i in frames(from: s.start, to: s.end, rate: sampleRate, count: buffer.count) {
      let t = Double(i) / sampleRate
      var sample = sin(carrierPhase) * gain.value(at: t)
      if let lfo = s.gainLFO { sample *= lfo.gainMultiplier(at: t - s.start) }
      buffer[i] += sample
      var instant = s.frequency + s.frequency * index.value(at: t) * sin(modulatorPhase)
      if let lfo = s.pitchLFO { instant += lfo.depth * lfo.value(at: t - s.start) }
      carrierPhase += 2 * Double.pi * instant / sampleRate
      modulatorPhase += modulatorStep
    }
  }

  private static func renderNoise(
    _ s: NoiseSpec, into buffer: inout [Double], sampleRate: Double, seed: UInt64
  ) {
    let cutoff = s.cutoff.automation(start: s.start, duration: s.duration)
    let gain = s.envelope.automation(start: s.start, duration: s.duration, scale: s.gain)
    // カットオフが動かなければ係数は不変なので 1 度だけ組む。
    let fixed = s.cutoff.constantValue.map {
      Biquad.coefficients(kind: s.kind, frequency: $0, q: s.q, sampleRate: sampleRate)
    }

    var noise = WhiteNoise(seed: seed)
    var filter = Biquad()
    for i in frames(from: s.start, to: s.end, rate: sampleRate, count: buffer.count) {
      let t = Double(i) / sampleRate
      let coefficients =
        fixed
        ?? Biquad.coefficients(
          kind: s.kind, frequency: cutoff.value(at: t), q: s.q, sampleRate: sampleRate)
      buffer[i] += filter.process(noise.next(), coefficients) * gain.value(at: t)
    }
  }
}
