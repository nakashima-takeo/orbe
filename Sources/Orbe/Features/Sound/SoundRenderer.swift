import Foundation

/// 案 × イベント × 音量 × サンプルレートから、決定論的にモノラル PCM を組む。
///
/// マスタチェーンは design の順そのまま: 全部品を加算 → × 音量 → コンプレッサ。
/// **音量がコンプレッサの手前**にあるのが要点で、音量を上げるほど圧縮が深くなる（＝音量は再生側の
/// ボリュームではなく合成の入力）。事前生成した音声ファイルを同梱するとこの順が崩れる。
enum SoundRenderer {
  /// 音量は 0〜100（%）。0 は呼ばれない想定（`AgentSoundDecision` が手前で弾く）。
  static func render(
    family: NotificationSound, event: AgentSoundEvent, volume: Int, sampleRate: Double
  ) -> [Float] {
    let components = SoundCatalog.components(family, event)
    let total = SoundCatalog.duration(family, event)
    let frameCount = max(1, Int((total * sampleRate).rounded(.up)))
    var buffer = [Double](repeating: 0, count: frameCount)

    for (index, component) in components.enumerated() {
      switch component {
      case .tone(let spec): renderTone(spec, into: &buffer, sampleRate: sampleRate)
      case .glide(let spec): renderGlide(spec, into: &buffer, sampleRate: sampleRate)
      case .fm(let spec): renderFM(spec, into: &buffer, sampleRate: sampleRate)
      case .noise(let spec):
        renderNoise(
          spec, into: &buffer, sampleRate: sampleRate,
          seed: noiseSeed(family: family, event: event, index: index))
      }
    }

    let level = Double(volume) / 100
    for i in buffer.indices { buffer[i] *= level }
    DynamicsCompressor.apply(to: &buffer, sampleRate: sampleRate)
    return buffer.map { Float($0) }
  }

  /// 部品ごとに違う（が毎回同じ）ノイズ列を出すためのシード。Swift の `Hasher` はプロセスごとに
  /// 種が変わるので使えない——決定論が崩れるとテストが再現しない。
  private static func noiseSeed(family: NotificationSound, event: AgentSoundEvent, index: Int)
    -> UInt64
  {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in "\(family.rawValue)/\(event.rawValue)".utf8 {
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

  /// ゲインの 3 イベント（`setValue(zero)` → `ramp(gain, a)` → `ramp(zero, d)`）。
  /// 減衰が進むのは `d` ではなく `d - a`（指数ランプの起点は直前のイベントの時刻）。
  private static func envelope(start: Double, attack: Double, duration: Double, gain: Double)
    -> AudioParam
  {
    var param = AudioParam(AudioParam.zero, at: start)
    param.rampExponentially(to: gain, at: start + attack)
    param.rampExponentially(to: AudioParam.zero, at: start + duration)
    return param
  }

  private static func renderTone(_ s: ToneSpec, into buffer: inout [Double], sampleRate: Double) {
    let gain = envelope(start: s.start, attack: s.attack, duration: s.duration, gain: s.gain)
    let coefficients = s.lowpass.map {
      // Web Audio の lowpass の Q 既定は 1（dB 解釈）。
      Biquad.coefficients(kind: .lowpass, frequency: $0, q: 1, sampleRate: sampleRate)
    }
    var filter = Biquad()
    var phase = 0.0
    let step = 2 * Double.pi * s.frequency / sampleRate
    for i in frames(from: s.start, to: s.end, rate: sampleRate, count: buffer.count) {
      let t = Double(i) / sampleRate
      var sample =
        s.waveform.sample(phase: phase, frequency: s.frequency, sampleRate: sampleRate)
        * gain.value(at: t)
      if let coefficients { sample = filter.process(sample, coefficients) }
      buffer[i] += sample
      phase += step
    }
  }

  private static func renderGlide(_ s: GlideSpec, into buffer: inout [Double], sampleRate: Double) {
    var frequency = AudioParam(s.from, at: s.start)
    if let overshoot = s.overshoot {
      frequency.rampExponentially(to: s.to * overshoot, at: s.start + s.duration * 0.6)
    }
    frequency.rampExponentially(to: s.to, at: s.start + s.duration)

    // glide のゲインは 4 イベント（0.02 で立ち上がり、0.7d まで平坦、d+0.15 で消える）。
    var gain = AudioParam(AudioParam.zero, at: s.start)
    gain.rampExponentially(to: s.gain, at: s.start + 0.02)
    gain.setValue(s.gain, at: s.start + s.duration * 0.7)
    gain.rampExponentially(to: AudioParam.zero, at: s.start + s.duration + 0.15)

    var phase = 0.0
    for i in frames(from: s.start, to: s.end, rate: sampleRate, count: buffer.count) {
      let t = Double(i) / sampleRate
      var instant = frequency.value(at: t)
      if s.vibrato != 0, t <= s.vibratoEnd {
        instant += s.vibrato * sin(2 * Double.pi * s.vibratoRate * (t - s.start))
      }
      instant = max(instant, 1)
      buffer[i] +=
        s.waveform.sample(phase: phase, frequency: instant, sampleRate: sampleRate)
        * gain.value(at: t)
      phase += 2 * Double.pi * instant / sampleRate
    }
  }

  private static func renderFM(_ s: FMSpec, into buffer: inout [Double], sampleRate: Double) {
    // モジュレータのゲインは Hz 単位の周波数偏移。
    var deviation = AudioParam(s.frequency * s.index, at: s.start)
    deviation.rampExponentially(
      to: s.frequency * 0.02, at: s.start + s.duration * s.modulatorDecay)
    let gain = envelope(start: s.start, attack: 0.004, duration: s.duration, gain: s.gain)

    var carrierPhase = 0.0
    var modulatorPhase = 0.0
    let modulatorStep = 2 * Double.pi * s.frequency * s.ratio / sampleRate
    for i in frames(from: s.start, to: s.end, rate: sampleRate, count: buffer.count) {
      let t = Double(i) / sampleRate
      buffer[i] += sin(carrierPhase) * gain.value(at: t)
      let instant = s.frequency + deviation.value(at: t) * sin(modulatorPhase)
      carrierPhase += 2 * Double.pi * instant / sampleRate
      modulatorPhase += modulatorStep
    }
  }

  private static func renderNoise(
    _ s: NoiseSpec, into buffer: inout [Double], sampleRate: Double, seed: UInt64
  ) {
    var frequency = AudioParam(s.frequency, at: s.start)
    if let end = s.frequencyEnd { frequency.rampExponentially(to: end, at: s.start + s.duration) }
    let gain = envelope(start: s.start, attack: s.attack, duration: s.duration, gain: s.gain)
    // 周波数が自動化されていなければ係数は不変なので 1 度だけ組む。
    let fixed =
      s.frequencyEnd == nil
      ? Biquad.coefficients(
        kind: s.kind, frequency: s.frequency, q: s.q, sampleRate: sampleRate) : nil

    var noise = WhiteNoise(seed: seed)
    var filter = Biquad()
    for i in frames(from: s.start, to: s.end, rate: sampleRate, count: buffer.count) {
      let t = Double(i) / sampleRate
      let coefficients =
        fixed
        ?? Biquad.coefficients(
          kind: s.kind, frequency: frequency.value(at: t), q: s.q, sampleRate: sampleRate)
      buffer[i] += filter.process(noise.next(), coefficients) * gain.value(at: t)
    }
  }
}
