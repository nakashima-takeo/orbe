import Foundation

/// ミックス済みバッファ全体へ掛ける後段エフェクト。部品の加算 → エフェクト列 → 音量 →
/// コンプレッサの順で適用される純関数（同一入力 → 同一出力。状態はこの関数の中で完結する）。
public enum SoundEffect: Hashable {
  /// フィードバックディレイ。`time` 秒遅れの繰り返しが `feedback`（0..<1）倍ずつ減衰し、
  /// 繰り返すたびに 1 次ローパス（カットオフ `damping` Hz）で高域が丸まる——遠ざかる反響ほど
  /// こもる、空間の最初の一歩。`mix` はウェット量（0 = 素通し、1 = 遅延音を原音と等量で加算）。
  ///
  /// テールはバッファの端で打ち切られる。`SoundProgram.duration` を「テール込みの全長」として
  /// 決めるのは呼び出し側の責任（エフェクトはバッファを伸ばさない）。
  case delay(time: Double, feedback: Double, damping: Double, mix: Double)

  func apply(to buffer: inout [Double], sampleRate: Double) {
    switch self {
    case .delay(let time, let feedback, let damping, let mix):
      let delaySamples = max(1, Int((time * sampleRate).rounded()))
      var line = [Double](repeating: 0, count: delaySamples)
      // フィードバック経路の 1 次ローパス。係数はカットオフ `damping` Hz の 1 極形。
      let coefficient = exp(-2 * Double.pi * min(max(damping, 1), sampleRate / 2) / sampleRate)
      var lowpassed = 0.0
      var index = 0
      for i in buffer.indices {
        let delayed = line[index]
        lowpassed = (1 - coefficient) * delayed + coefficient * lowpassed
        line[index] = buffer[i] + lowpassed * feedback
        buffer[i] += lowpassed * mix
        index += 1
        if index == delaySamples { index = 0 }
      }
    }
  }
}
