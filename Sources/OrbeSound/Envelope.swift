import Foundation

/// 部品 1 つのパラメータの時間形状（ブレークポイント列）。ゲイン・FM のモジュレーション
/// インデックス・フィルタのカットオフなど「時刻 → 値」で動くものすべてをこの 1 つの語彙で書く。
///
/// 各点の時刻は `fraction * duration + offset`（秒・部品の発音開始からの相対）で解決する。
/// 部品の長さに対する比率（0 = 発音開始、1 = 発音終了）と絶対秒の和で表すことで、
/// 「立ち上がり 4ms」（絶対）と「全長の 7 割まで平坦」（比率）を同じ列に混在できる。
/// 点は時刻昇順で並べる（`AudioParam` のイベント列と同じ前提）。
public struct Envelope: Hashable {
  /// 直前の点からこの点までの結び方。
  public enum Curve: Hashable {
    /// 直前の値を保持し、この点の時刻で新しい値へ跳ぶ。
    case step
    /// 直線で結ぶ。指数が幾何平均で補間するのに対し、こちらは算術平均で補間する。
    case linear
    /// 指数（等比）で結ぶ。減衰・立ち上がりの自然な形。指数は 0 を扱えないため、
    /// 値 0 は可聴下限の `AudioParam.zero` に読み替えて展開する。
    case exponential
  }

  public struct Point: Hashable {
    /// 部品の `duration` に対する比率（0 = 発音開始、1 = 発音終了）。
    public var fraction: Double
    /// 比率で解決した時刻へ足す絶対秒。
    public var offset: Double
    /// この点で到達する値。ゲインエンベロープでは公称レベル 1 に対する比、
    /// カットオフやインデックスのエンベロープではその量そのもの。
    public var value: Double
    public var curve: Curve

    public init(fraction: Double = 0, offset: Double = 0, value: Double, curve: Curve) {
      self.fraction = fraction
      self.offset = offset
      self.value = value
      self.curve = curve
    }

    func time(duration: Double) -> Double { fraction * duration + offset }
  }

  public var points: [Point]

  public init(points: [Point]) { self.points = points }

  // MARK: - 便宜形

  /// 任意のブレークポイント列。
  public static func breakpoints(_ points: [Point]) -> Envelope { Envelope(points: points) }

  /// 打楽器的な形: `attack` 秒で公称レベルへ指数で立ち上がり、発音終了（`duration`）まで
  /// 指数で消える。
  public static func percussive(attack: Double) -> Envelope {
    breakpoints([
      Point(value: 0, curve: .step),
      Point(offset: attack, value: 1, curve: .exponential),
      Point(fraction: 1, value: 0, curve: .exponential),
    ])
  }

  /// ADSR: `attack` 秒で公称レベルへ、続く `decay` 秒で `sustain` へ落ち、発音終了まで保持し、
  /// その後 `release` 秒かけて消える（部品の `end` は release まで含む）。
  public static func adsr(attack: Double, decay: Double, sustain: Double, release: Double)
    -> Envelope
  {
    breakpoints([
      Point(value: 0, curve: .step),
      Point(offset: attack, value: 1, curve: .linear),
      Point(offset: attack + decay, value: sustain, curve: .exponential),
      Point(fraction: 1, value: sustain, curve: .step),
      Point(fraction: 1, offset: release, value: 0, curve: .linear),
    ])
  }

  /// ゲート形: `attack` 秒で公称レベルへ達し、全長の `sustainFraction` まで平坦に保持し、
  /// 発音終了の `release` 秒後に指数で消える。
  public static func gate(attack: Double, sustainFraction: Double, release: Double) -> Envelope {
    breakpoints([
      Point(value: 0, curve: .step),
      Point(offset: attack, value: 1, curve: .exponential),
      Point(fraction: sustainFraction, value: 1, curve: .step),
      Point(fraction: 1, offset: release, value: 0, curve: .exponential),
    ])
  }

  /// 一定値（カットオフを動かさない noise など）。
  public static func constant(_ value: Double) -> Envelope {
    breakpoints([Point(value: value, curve: .step)])
  }

  /// 始値から終値へ 1 本の指数で移り、以降は保持する。到達は全長の `endFraction` の時点。
  /// FM インデックスの減衰やフィルタスイープの素直な形。
  public static func sweep(from: Double, to: Double, endFraction: Double = 1) -> Envelope {
    breakpoints([
      Point(value: from, curve: .step),
      Point(fraction: endFraction, value: to, curve: .exponential),
    ])
  }

  // MARK: - 展開

  /// 部品の実時刻へ展開した `AudioParam`。`scale` は値に掛ける係数（ゲインエンベロープは部品の
  /// gain、Hz やインデックスなど絶対量のエンベロープは 1）。値 0 は指数ランプが扱えないため
  /// `AudioParam.zero`（可聴下限）へ読み替える——linear / step でも同じ読み替えにして、
  /// 曲線の種類で「無音の値」が割れないようにする。
  func automation(start: Double, duration: Double, scale: Double = 1) -> AudioParam {
    func resolved(_ point: Point) -> Double {
      point.value == 0 ? AudioParam.zero : point.value * scale
    }
    guard let first = points.first else { return AudioParam(AudioParam.zero, at: start) }
    var param = AudioParam(resolved(first), at: start + first.time(duration: duration))
    for point in points.dropFirst() {
      let time = start + point.time(duration: duration)
      switch point.curve {
      case .step: param.setValue(resolved(point), at: time)
      case .linear: param.rampLinearly(to: resolved(point), at: time)
      case .exponential: param.rampExponentially(to: resolved(point), at: time)
      }
    }
    return param
  }

  /// 発音が終わる時刻（部品の `end` 計算に使う）。最後の点は `duration` より手前にも置けるが、
  /// 部品の長さは指定した `duration` を下回らせない。
  func end(duration: Double) -> Double {
    max(duration, points.map { $0.time(duration: duration) }.max() ?? duration)
  }

  /// 全点が同じ値ならその値。カットオフが動かない noise でフィルタ係数を 1 度だけ組む判定に使う。
  var constantValue: Double? {
    guard let value = points.first?.value, points.allSatisfy({ $0.value == value }) else {
      return nil
    }
    return value
  }
}
