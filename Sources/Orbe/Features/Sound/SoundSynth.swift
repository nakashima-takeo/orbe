import Foundation

/// 通知音の合成プリミティブ。design（Web Audio のノードグラフ）の意味論を Swift の純関数へ写したもので、
/// 音を出す手段は一切持たない（再生は `SoundPlayer`、音の定義は `SoundCatalog`、組み立ては `SoundRenderer`）。
///
/// 同じ入力から常に同じ波形が出る（乱数も固定シード）。だから波形そのものをテストで機械検証できる。

/// Web Audio の `AudioParam`（時刻 → 値のオートメーション）。design が使うのは `setValueAtTime` と
/// `exponentialRampToValueAtTime` の 2 つだけなので、その 2 種のイベント列として持つ。
///
/// 指数ランプの起点は**直前のイベントの (時刻, 値)** であって「その区間の始まり」ではない。
/// tone のエンベロープ（setValue → ramp(a) → ramp(d)）で減衰が進むのは `d` でなく `d - a` の長さ
/// ——ここを取り違えると全案が一様に長く聞こえる。
struct AudioParam {
  /// 指数ランプは 0 を扱えない（v0・v1 は同符号かつ非ゼロ）。design はこの値を「ゼロ代わり」に使う。
  /// 0 へ丸めると立ち上がりと減衰のカーブが変わるので、そのまま持つ。
  static let zero = 0.0001

  private enum Ramp { case step, exponential }
  private struct Event {
    let time: Double
    let value: Double
    let ramp: Ramp
  }
  private var events: [Event]

  /// 先頭の `setValueAtTime`。イベント列は必ず 1 つ以上を持つ（値が定まらない時刻を作らない）。
  init(_ value: Double, at time: Double) {
    events = [Event(time: time, value: value, ramp: .step)]
  }

  /// `setValueAtTime(v, t)`: 時刻 t 以降、次のイベントまで値は v。
  mutating func setValue(_ value: Double, at time: Double) {
    events.append(Event(time: time, value: value, ramp: .step))
  }

  /// `exponentialRampToValueAtTime(v, t)`: 直前のイベントを起点に t まで指数で結ぶ。
  mutating func rampExponentially(to value: Double, at time: Double) {
    events.append(Event(time: time, value: value, ramp: .exponential))
  }

  /// 任意時刻の値。イベント列は追加順＝時刻昇順で積まれている前提（design のどの音もそう組む）。
  func value(at time: Double) -> Double {
    let first = events[0]
    if time <= first.time { return first.value }
    var i = 0
    while i + 1 < events.count, events[i + 1].time <= time { i += 1 }
    guard i + 1 < events.count else { return events[i].value }
    let next = events[i + 1]
    switch next.ramp {
    case .step:
      return events[i].value  // 次のイベントが撃たれるまで直前の値を保持する
    case .exponential:
      let t0 = events[i].time
      let v0 = events[i].value
      guard next.time > t0, v0 > 0, next.value > 0 else { return next.value }
      return v0 * pow(next.value / v0, (time - t0) / (next.time - t0))
    }
  }
}

/// オシレータの波形。Web Audio と同じく**帯域制限した理想波形**（Nyquist を超える倍音を足さない）。
/// 素朴な生成だとエイリアスが乗り、矩形波の案（遊技）と三角波の案（電紫・弾み）がジャリつく。
enum Waveform {
  case sine, square, triangle

  /// 位相 φ（rad）と瞬時周波数から 1 サンプル。倍音は `k * frequency < Nyquist` の範囲だけ加算する。
  /// Web Audio は倍音テーブルをピーク 1 へ正規化するため素の級数（ピーク約 1.09）と数 % のレベル差が
  /// 出るが、聴感上は無視できる差なので級数のまま使う。
  func sample(phase: Double, frequency: Double, sampleRate: Double) -> Double {
    switch self {
    case .sine:
      return sin(phase)
    case .square:
      var sum = 0.0
      var k = 1.0
      let nyquist = sampleRate / 2
      while k * frequency < nyquist {
        sum += sin(k * phase) / k
        k += 2
      }
      return sum * (4 / Double.pi)
    case .triangle:
      var sum = 0.0
      var k = 1.0
      var sign = 1.0
      let nyquist = sampleRate / 2
      while k * frequency < nyquist {
        sum += sign * sin(k * phase) / (k * k)
        sign = -sign
        k += 2
      }
      return sum * (8 / (Double.pi * Double.pi))
    }
  }
}

/// Web Audio `BiquadFilterNode`（＝RBJ Audio EQ Cookbook）の係数と Direct Form I の適用。
///
/// **Q の解釈が種別で違う**: lowpass / highpass はデシベル（Web Audio 仕様の規定）、bandpass は線形。
/// 取り違えると遊技のこもり具合・気配や洋琴のノイズの色が変わる。
struct Biquad {
  enum Kind { case lowpass, highpass, bandpass }

  /// a0 で正規化済みの係数。
  struct Coefficients: Equatable {
    let b0, b1, b2, a1, a2: Double
  }

  static func coefficients(
    kind: Kind, frequency: Double, q: Double, sampleRate: Double
  ) -> Coefficients {
    let nyquist = sampleRate / 2
    let f0 = min(max(frequency, 1), nyquist * 0.999)
    let w0 = 2 * Double.pi * f0 / sampleRate
    let cosW = cos(w0)
    let sinW = sin(w0)
    // lowpass / highpass の Q は dB（10^(Q/20) が実効の Q）、bandpass の Q は線形。
    let alpha: Double
    switch kind {
    case .lowpass, .highpass: alpha = sinW / (2 * pow(10, q / 20))
    case .bandpass: alpha = sinW / (2 * max(q, 0.0001))
    }
    let a0 = 1 + alpha
    let a1 = -2 * cosW
    let a2 = 1 - alpha
    let b0: Double
    let b1: Double
    let b2: Double
    switch kind {
    case .lowpass:
      b0 = (1 - cosW) / 2
      b1 = 1 - cosW
      b2 = (1 - cosW) / 2
    case .highpass:
      b0 = (1 + cosW) / 2
      b1 = -(1 + cosW)
      b2 = (1 + cosW) / 2
    case .bandpass:  // constant 0dB peak gain
      b0 = alpha
      b1 = 0
      b2 = -alpha
    }
    return Coefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
  }

  private var x1 = 0.0
  private var x2 = 0.0
  private var y1 = 0.0
  private var y2 = 0.0

  /// 係数を毎サンプル受け取る（周波数が自動化されている noise は係数がサンプルごとに変わる）。
  mutating func process(_ x: Double, _ c: Coefficients) -> Double {
    let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
    x2 = x1
    x1 = x
    y2 = y1
    y1 = y
    return y
  }
}

/// 白色雑音（一様分布 [-1, 1)）。design の `Math.random() * 2 - 1` と同じ分布を、固定シードの
/// SplitMix64 で決定論的に出す（毎回同じ波形＝テストが再現する。白色なので聴感上の性格は同じ）。
struct WhiteNoise {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= (z >> 31)
    // 上位 53bit を [0, 1) の倍精度へ（一様）。
    return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0) * 2 - 1
  }
}

/// Web Audio `DynamicsCompressorNode` を**全パラメータ既定値**で使う master のコンプレッサ。
/// 仕様が規定するのはソフトニーの静特性だけで、Chrome 実装固有の細部（約 6ms の先読みディレイ・
/// 多段リリースカーブ）は非公開。ここは静特性＋1 次追従で「圧縮の量と時定数」を合わせる
/// ——これがブラウザと Orbe の音が完全一致しない唯一の要因になる。
enum DynamicsCompressor {
  static let threshold = -24.0  // dB
  static let knee = 30.0  // dB
  static let ratio = 12.0
  static let attack = 0.003  // s
  static let release = 0.25  // s

  /// 静特性（入力 dB → 出力 dB）。ニーの下は素通し、ニーの中は二次で滑らかに、上は比で圧縮。
  static func curve(inputDB x: Double) -> Double {
    if x < threshold - knee / 2 { return x }
    if x <= threshold + knee / 2 {
      let over = x - threshold + knee / 2
      return x + (1 / ratio - 1) * over * over / (2 * knee)
    }
    return threshold + (x - threshold) / ratio
  }

  /// ピーク検出＋1 次追従で全サンプルへ掛ける（in-place）。makeup gain は無し（design と同じ既定）。
  static func apply(to samples: inout [Double], sampleRate: Double) {
    let coefAttack = exp(-1 / (attack * sampleRate))
    let coefRelease = exp(-1 / (release * sampleRate))
    var state = 0.0  // 現在のゲインリダクション（dB・0 以下）
    for i in samples.indices {
      let level = 20 * log10(max(abs(samples[i]), 1e-9))
      let target = curve(inputDB: level) - level  // 0 以下
      // 深くなる方向が attack、戻る方向が release。
      let coef = target < state ? coefAttack : coefRelease
      state = target + (state - target) * coef
      samples[i] *= pow(10, state / 20)
    }
  }
}
