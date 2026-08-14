import Foundation

/// 音 1 つを構成する最小部品（design のプリミティブを展開した後の低レベル部品）。
/// `SoundCatalog` が案ごとにこの配列を組み、`SoundRenderer` が 1 本のモノラル波形へ加算する。
public enum SoundComponent: Hashable {
  case tone(ToneSpec)
  case glide(GlideSpec)
  case fm(FMSpec)
  case noise(NoiseSpec)

  /// 発音が終わる時刻（音の先頭からの秒）。レンダリング長はこの最大値から決まる。
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

/// 単一周波数の音。`lowpass` を指定するとゲインの後段に lowpass biquad（Q は Web Audio 既定の 1 dB）が入る。
public struct ToneSpec: Hashable {
  var frequency: Double
  var start: Double
  var duration: Double
  var waveform: Waveform = .sine
  var gain: Double
  var attack: Double = 0.004
  var lowpass: Double?

  var end: Double { start + duration + 0.05 }
}

/// 音程が滑る音。`overshoot` 指定時は t+0.6d で `to * overshoot` を経由してから `to` へ落ち着く
/// （弾みの跳ね上がり）。`vibrato`（Hz 幅）が非 0 なら sine の LFO を周波数へ加算する。
public struct GlideSpec: Hashable {
  var from: Double
  var to: Double
  var start: Double
  var duration: Double
  var waveform: Waveform = .sine
  var gain: Double
  var overshoot: Double?
  var vibrato: Double = 0
  var vibratoRate: Double = 6

  var end: Double { start + duration + 0.5 }
  /// LFO が効く区間の終わり。
  var vibratoEnd: Double { start + duration + 0.3 }
}

/// FM 合成の金属打音。キャリア `frequency`・モジュレータ `frequency * ratio`、
/// 周波数偏移は `frequency * index` から `frequency * 0.02` へ指数減衰する。
public struct FMSpec: Hashable {
  var frequency: Double
  var start: Double
  var duration: Double
  var ratio: Double
  var index: Double
  var gain: Double
  var modulatorDecay: Double = 0.5

  var end: Double { start + duration + 0.05 }
}

/// 帯域を通した白色雑音。`frequencyEnd` 指定時はフィルタ周波数が duration をかけて指数で移る。
public struct NoiseSpec: Hashable {
  var start: Double
  var duration: Double
  var gain: Double
  var kind: Biquad.Kind
  var frequency: Double
  var frequencyEnd: Double?
  /// 単位は `kind` で変わる——lowpass / highpass は dB、bandpass は線形（→ `Biquad`）。
  var q: Double = 0.8
  var attack: Double = 0.01

  var end: Double { start + duration + 0.1 }
}

/// 複数部品へ展開される合成プリミティブ（design の `bell` / `knock` / `piano`）。
/// 案の定義（`SoundCatalog`）から素の周波数表を追い出し、音色の作り方を 1 箇所に持つ。
extension SoundCatalog {
  /// 澄んだ鐘。非整数比の倍音 3 本で、上の倍音ほど短く消える（`d / (1 + r * 0.35)`。基音は割らない）。
  static func bell(_ f: Double, at t: Double, duration d: Double, gain g: Double)
    -> [SoundComponent]
  {
    let partials: [(ratio: Double, gain: Double)] = [(1.00, 1.00), (2.76, 0.35), (5.40, 0.12)]
    return partials.map { partial in
      let duration = partial.ratio > 1 ? d / (1 + partial.ratio * 0.35) : d
      return .tone(
        ToneSpec(
          frequency: f * partial.ratio, start: t, duration: duration, gain: g * partial.gain,
          attack: 0.003))
    }
  }

  /// マリンバ調の打音。基音＋4 倍音の短い添えに、打点のノイズを一瞬だけ重ねる。
  static func knock(_ f: Double, at t: Double, duration d: Double, gain g: Double)
    -> [SoundComponent]
  {
    [
      .tone(ToneSpec(frequency: f, start: t, duration: d, gain: g, attack: 0.002)),
      .tone(ToneSpec(frequency: f * 4, start: t, duration: d * 0.3, gain: g * 0.4, attack: 0.002)),
      .noise(
        NoiseSpec(
          start: t, duration: 0.03, gain: g * 0.5, kind: .bandpass, frequency: min(f * 6, 8000),
          q: 1)),
    ]
  }

  /// ピアノの打鍵。倍音 6 本を僅かに非調和（弦のインハーモニシティ）にして減衰差をつけ、
  /// ハンマーの当たりを高域ノイズで足す。
  static func piano(_ f: Double, at t: Double, duration d: Double, gain g: Double)
    -> [SoundComponent]
  {
    let gains = [1.00, 0.50, 0.28, 0.16, 0.09, 0.05]
    var out: [SoundComponent] = gains.indices.map { i in
      let n = Double(i + 1)
      let ratio = n * (1 + 0.0004 * n * n)
      return .tone(
        ToneSpec(
          frequency: f * ratio, start: t, duration: d / (1 + n * 0.45), gain: g * gains[i],
          attack: 0.002))
    }
    out.append(
      .noise(
        NoiseSpec(
          start: t, duration: 0.015, gain: g * 0.25, kind: .highpass, frequency: 2500, q: 0.5,
          attack: 0.001)))
    return out
  }
}
