import Foundation

/// 合成結果の数値解析。ラウドネス整合（全案の RMS を帯域内に保つ）の判定材料と、
/// 制作ループでの音の観察（orbe-sound analyze）をテストと CLI で共用する。
/// 外部依存なし・決定論——同じ波形からは常に同じ数値が出る。
public enum SoundAnalysis {
  public struct SpectralPeak {
    /// ピークの周波数（Hz）。分解能は DFT 窓長で決まる（48kHz・窓 4096 で約 11.7 Hz）。
    public let frequency: Double
    /// 最大ピークに対する相対レベル（最大 = 0 dB）。
    public let levelDB: Double
  }

  public struct Result {
    public let duration: Double
    /// 最大振幅（dBFS。1.0 = 0 dB）。
    public let peakDB: Double
    /// 全長の実効値（dBFS）。ラウドネス整合はこの値を帯域で縛る。
    public let rmsDB: Double
    /// ピークと RMS の差（dB）。打撃的な音ほど大きい。
    public let crestDB: Double
    /// スペクトルの上位ピーク（相対レベル降順）。
    public let spectralPeaks: [SpectralPeak]
  }

  public static func analyze(
    _ samples: [Float], sampleRate: Double, peakCount: Int = 5
  ) -> Result {
    Result(
      duration: Double(samples.count) / sampleRate,
      peakDB: peakDB(samples),
      rmsDB: rmsDB(samples),
      crestDB: peakDB(samples) - rmsDB(samples),
      spectralPeaks: spectralPeaks(samples, sampleRate: sampleRate, count: peakCount))
  }

  /// 最大振幅（dBFS）。無音は -Double.infinity。
  public static func peakDB(_ samples: [Float]) -> Double {
    let peak = samples.reduce(0.0) { max($0, Double(abs($1))) }
    return 20 * log10(peak)
  }

  /// 全長の実効値（dBFS）。無音は -Double.infinity。
  public static func rmsDB(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else { return -.infinity }
    let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    return 10 * log10(sum / Double(samples.count))
  }

  /// スペクトルの上位ピーク。最大振幅サンプルを含む窓（Hann・最長 4096）を素朴な DFT に掛け、
  /// 振幅スペクトルの局所極大を相対レベル降順で返す。-60 dB より弱いピークは棚に埋もれた
  /// ゆらぎなので返さない。
  public static func spectralPeaks(_ samples: [Float], sampleRate: Double, count: Int)
    -> [SpectralPeak]
  {
    // count 0 は「ピーク不要」（analyze --all の一覧など）。DFT は O(n²) なので回さず返す。
    guard count > 0, samples.count >= 16 else { return [] }
    let window = min(4096, samples.count)
    // 窓は最大振幅サンプルから始める（減衰音の tonal な本体を捉える）。端では収まる位置へ寄せる。
    var start = 0
    var peak: Float = 0
    for (i, sample) in samples.enumerated() where abs(sample) > peak {
      peak = abs(sample)
      start = i
    }
    start = min(start, samples.count - window)

    // Hann 窓を掛けた実信号の DFT 振幅。sin/cos は回転漸化式で進め、素朴な O(n^2) を実用速度に保つ。
    var windowed = [Double](repeating: 0, count: window)
    for i in 0..<window {
      let hann = 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(window - 1)))
      windowed[i] = Double(samples[start + i]) * hann
    }
    let bins = window / 2
    var magnitudes = [Double](repeating: 0, count: bins)
    for k in 1..<bins {
      let angle = -2 * Double.pi * Double(k) / Double(window)
      let rotateCos = cos(angle)
      let rotateSin = sin(angle)
      var cosine = 1.0
      var sine = 0.0
      var real = 0.0
      var imaginary = 0.0
      for value in windowed {
        real += value * cosine
        imaginary += value * sine
        let next = cosine * rotateCos - sine * rotateSin
        sine = cosine * rotateSin + sine * rotateCos
        cosine = next
      }
      magnitudes[k] = (real * real + imaginary * imaginary).squareRoot()
    }

    // 局所極大 → 相対レベル降順 → 上位 count 件。
    guard let strongest = magnitudes.max(), strongest > 0 else { return [] }
    var found: [SpectralPeak] = []
    for k in 1..<(bins - 1)
    where magnitudes[k] > magnitudes[k - 1] && magnitudes[k] >= magnitudes[k + 1] {
      let level = 20 * log10(magnitudes[k] / strongest)
      guard level > -60 else { continue }
      found.append(
        SpectralPeak(frequency: Double(k) * sampleRate / Double(window), levelDB: level))
    }
    return Array(found.sorted { $0.levelDB > $1.levelDB }.prefix(count))
  }
}
