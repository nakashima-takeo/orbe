import Foundation

/// 音 1 つの完全な定義（部品列 + 後段エフェクト列 + 全長）。カタログの 1 案 × 1 イベントも
/// 制作用 scratch の 1 エントリも同じこの形で表し、`SoundRenderer` がそのまま合成する。
public struct SoundProgram: Hashable {
  public var components: [SoundComponent]
  /// 部品ミックスの後に順番に適用するエフェクト列（→ `SoundEffect`）。
  public var effects: [SoundEffect]
  /// 音の全長（秒）。**エフェクトのテール込み**の長さで、レンダリングはここで打ち切られる。
  /// 省略時は最後の部品の発音が終わる時刻——エフェクトが無ければ以降は厳密に無音なので、
  /// 足すべき余白は無い。ディレイを掛けるならテールが収まる長さを明示する。
  public var duration: Double
  /// ラウドネス整合のトリム（dB）。部品ミックス全体へエフェクトの前に掛かる——全部品の
  /// gain を一律に増減するのと等価で、音の内部バランスと音色の手書き値を崩さずに音量だけ動かす。
  public var trimDB: Double

  public init(
    components: [SoundComponent], effects: [SoundEffect] = [], duration: Double? = nil,
    trimDB: Double = 0
  ) {
    self.components = components
    self.effects = effects
    self.duration = duration ?? components.map(\.end).max() ?? 0
    self.trimDB = trimDB
  }
}

/// 低周波オシレータ。部品の `pitchLFO`（ビブラート: Hz 幅で瞬時周波数へ加算）と
/// `gainLFO`（トレモロ: 公称ゲインを 1 − depth…1 の間で揺らす）の 2 用途を 1 つの語彙で持つ。
public struct LFO: Hashable {
  /// 揺れの速さ（Hz）。
  public var rate: Double
  /// 揺れの幅。ビブラートでは Hz、トレモロでは 0…1 の変調深さ。
  public var depth: Double

  public init(rate: Double, depth: Double) {
    self.rate = rate
    self.depth = depth
  }

  /// 発音開始からの経過秒 t における揺れ（-1…1）。0 から立ち上がる
  /// （鳴り始めに揺れの段差を作らない）。
  func value(at t: Double) -> Double { sin(2 * Double.pi * rate * t) }

  /// トレモロの振幅係数（1 − depth…1）。上限を公称ゲインに固定し、揺らしてもクリップ余地を
  /// 作らない（1 ± depth にすると depth ぶんピークが上がる）。
  func gainMultiplier(at t: Double) -> Double { 1 - depth * (1 - value(at: t)) / 2 }
}

/// 音 1 つを構成する最小部品。`SoundCatalog` が案ごとにこの配列を組み、
/// `SoundRenderer` が 1 本のモノラル波形へ加算する。
public enum SoundComponent: Hashable {
  case tone(ToneSpec)
  case glide(GlideSpec)
  case fm(FMSpec)
  case noise(NoiseSpec)

  /// 発音が終わる時刻（音の先頭からの秒）。エフェクト無しの音の全長はこの最大値から決まる。
  var end: Double {
    switch self {
    case .tone(let s): return s.end
    case .glide(let s): return s.end
    case .fm(let s): return s.end
    case .noise(let s): return s.end
    }
  }

  /// 発音が始まる時刻（音の先頭からの秒）。`end` と対で部品の整形式性を語る。
  var start: Double {
    switch self {
    case .tone(let s): return s.start
    case .glide(let s): return s.start
    case .fm(let s): return s.start
    case .noise(let s): return s.start
    }
  }
}

/// 単一周波数の音。`lowpass` を指定するとゲインの後段に lowpass biquad（Q は 1 dB）が入る。
public struct ToneSpec: Hashable {
  public var frequency: Double
  /// 周波数へのデチューン（セント）。ユニゾンの厚みは「デチューン違いの tone を複数並べる」で組む
  /// （部品の加算ミックスがそのまま重なりになる）。
  public var detuneCents: Double
  public var start: Double
  public var duration: Double
  public var waveform: Waveform
  public var gain: Double
  /// ゲインの時間形状（値 1 = `gain`）。
  public var envelope: Envelope
  public var lowpass: Double?
  public var pitchLFO: LFO?
  public var gainLFO: LFO?

  public init(
    frequency: Double, detuneCents: Double = 0, start: Double, duration: Double,
    waveform: Waveform = .sine, gain: Double, envelope: Envelope = .percussive(attack: 0.004),
    lowpass: Double? = nil, pitchLFO: LFO? = nil, gainLFO: LFO? = nil
  ) {
    self.frequency = frequency
    self.detuneCents = detuneCents
    self.start = start
    self.duration = duration
    self.waveform = waveform
    self.gain = gain
    self.envelope = envelope
    self.lowpass = lowpass
    self.pitchLFO = pitchLFO
    self.gainLFO = gainLFO
  }

  var end: Double { start + envelope.end(duration: duration) }
}

/// 音程が滑る音。`overshoot` 指定時は t+0.6d で `to * overshoot` を経由してから `to` へ落ち着く
/// （弾みの跳ね上がり）。
public struct GlideSpec: Hashable {
  public var from: Double
  public var to: Double
  public var detuneCents: Double
  public var start: Double
  public var duration: Double
  public var waveform: Waveform
  public var gain: Double
  public var overshoot: Double?
  /// ゲインの時間形状。既定は素早く立ち上がって全長の 7 割まで保持するゲート形
  /// （音程の動きが主役なので、鳴っている間はレベルを保つ）。
  public var envelope: Envelope
  public var pitchLFO: LFO?
  public var gainLFO: LFO?

  public init(
    from: Double, to: Double, detuneCents: Double = 0, start: Double, duration: Double,
    waveform: Waveform = .sine, gain: Double, overshoot: Double? = nil,
    envelope: Envelope = .gate(attack: 0.02, sustainFraction: 0.7, release: 0.15),
    pitchLFO: LFO? = nil, gainLFO: LFO? = nil
  ) {
    self.from = from
    self.to = to
    self.detuneCents = detuneCents
    self.start = start
    self.duration = duration
    self.waveform = waveform
    self.gain = gain
    self.overshoot = overshoot
    self.envelope = envelope
    self.pitchLFO = pitchLFO
    self.gainLFO = gainLFO
  }

  var end: Double { start + envelope.end(duration: duration) }
}

/// 2 オペレータ FM。キャリア `frequency`・モジュレータ `frequency * ratio`、
/// 周波数偏移は `frequency * index(t)`。`index` を減衰形にすると、立ち上がりだけ倍音が濃い
/// 金属打音になり、持ち上げれば逆に開いていく音も作れる。
public struct FMSpec: Hashable {
  public var frequency: Double
  public var start: Double
  public var duration: Double
  public var ratio: Double
  /// モジュレーションインデックスの時間形状（値はインデックスそのもの）。
  public var index: Envelope
  public var gain: Double
  /// ゲインの時間形状（値 1 = `gain`）。
  public var envelope: Envelope
  public var pitchLFO: LFO?
  public var gainLFO: LFO?

  public init(
    frequency: Double, start: Double, duration: Double, ratio: Double, index: Envelope,
    gain: Double, envelope: Envelope = .percussive(attack: 0.004), pitchLFO: LFO? = nil,
    gainLFO: LFO? = nil
  ) {
    self.frequency = frequency
    self.start = start
    self.duration = duration
    self.ratio = ratio
    self.index = index
    self.gain = gain
    self.envelope = envelope
    self.pitchLFO = pitchLFO
    self.gainLFO = gainLFO
  }

  var end: Double { start + envelope.end(duration: duration) }
}

/// 帯域を通した白色雑音。`cutoff` がフィルタのカットオフ / 中心周波数（Hz）の時間形状を持つ。
public struct NoiseSpec: Hashable {
  public var start: Double
  public var duration: Double
  public var gain: Double
  public var kind: FilterKind
  /// フィルタ周波数（Hz）のエンベロープ。`.constant` なら係数を 1 度だけ組む。
  public var cutoff: Envelope
  /// 単位は `kind` で変わる——lowpass / highpass は dB、bandpass は線形（→ `FilterKind`）。
  public var q: Double
  /// ゲインの時間形状（値 1 = `gain`）。
  public var envelope: Envelope

  public init(
    start: Double, duration: Double, gain: Double, kind: FilterKind, cutoff: Envelope,
    q: Double = 0.8, envelope: Envelope = .percussive(attack: 0.01)
  ) {
    self.start = start
    self.duration = duration
    self.gain = gain
    self.kind = kind
    self.cutoff = cutoff
    self.q = q
    self.envelope = envelope
  }

  var end: Double { start + envelope.end(duration: duration) }
}

/// 複数部品へ展開される音色ヘルパ（鐘・打音・打鍵）。案の定義（`SoundCatalog`）から素の周波数表を
/// 追い出し、音色の作り方を 1 箇所に持つ。scratch の音作りからも使える。
extension SoundCatalog {
  /// 澄んだ鐘。非整数比の倍音 3 本で、上の倍音ほど短く消える（`d / (1 + r * 0.35)`。基音は割らない）。
  public static func bell(_ f: Double, at t: Double, duration d: Double, gain g: Double)
    -> [SoundComponent]
  {
    let partials: [(ratio: Double, gain: Double)] = [(1.00, 1.00), (2.76, 0.35), (5.40, 0.12)]
    return partials.map { partial in
      let duration = partial.ratio > 1 ? d / (1 + partial.ratio * 0.35) : d
      return .tone(
        ToneSpec(
          frequency: f * partial.ratio, start: t, duration: duration, gain: g * partial.gain,
          envelope: .percussive(attack: 0.003)))
    }
  }

  /// マリンバ調の打音。基音＋4 倍音の短い添えに、打点のノイズを一瞬だけ重ねる。
  public static func knock(_ f: Double, at t: Double, duration d: Double, gain g: Double)
    -> [SoundComponent]
  {
    [
      .tone(
        ToneSpec(
          frequency: f, start: t, duration: d, gain: g, envelope: .percussive(attack: 0.002))),
      .tone(
        ToneSpec(
          frequency: f * 4, start: t, duration: d * 0.3, gain: g * 0.4,
          envelope: .percussive(attack: 0.002))),
      .noise(
        NoiseSpec(
          start: t, duration: 0.03, gain: g * 0.5, kind: .bandpass,
          cutoff: .constant(min(f * 6, 8000)), q: 1)),
    ]
  }

  /// ピアノの打鍵。倍音 6 本を僅かに非調和（弦のインハーモニシティ）にして減衰差をつけ、
  /// ハンマーの当たりを高域ノイズで足す。
  public static func piano(_ f: Double, at t: Double, duration d: Double, gain g: Double)
    -> [SoundComponent]
  {
    let gains = [1.00, 0.50, 0.28, 0.16, 0.09, 0.05]
    var out: [SoundComponent] = gains.indices.map { i in
      let n = Double(i + 1)
      let ratio = n * (1 + 0.0004 * n * n)
      return .tone(
        ToneSpec(
          frequency: f * ratio, start: t, duration: d / (1 + n * 0.45), gain: g * gains[i],
          envelope: .percussive(attack: 0.002)))
    }
    out.append(
      .noise(
        NoiseSpec(
          start: t, duration: 0.015, gain: g * 0.25, kind: .highpass, cutoff: .constant(2500),
          q: 0.5, envelope: .percussive(attack: 0.001))))
    return out
  }
}
