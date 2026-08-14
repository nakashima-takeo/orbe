import XCTest

@testable import OrbeSound

/// 数値解析の検証。L1 純ロジック・決定論。
/// ここが狂うと、ラウドネス整合テストと orbe-sound analyze の数値が物差しとして使えなくなる。
final class SoundAnalysisTests: XCTestCase {
  private let sampleRate = 48000.0

  /// 一定振幅 0.5 は peak = rms = -6.02 dBFS、クレスト 0（dB 換算の検算）。
  func testPeakAndRMSOfConstantSignal() {
    let samples = [Float](repeating: 0.5, count: 4800)
    let result = SoundAnalysis.analyze(samples, sampleRate: sampleRate)
    XCTAssertEqual(result.peakDB, -6.0206, accuracy: 1e-3)
    XCTAssertEqual(result.rmsDB, -6.0206, accuracy: 1e-3)
    XCTAssertEqual(result.crestDB, 0, accuracy: 1e-6)
    XCTAssertEqual(result.duration, 0.1, accuracy: 1e-9)
  }

  /// 正弦波の RMS はピークの -3.01 dB（整数周期で厳密）。
  func testSineRMSIsThreeDBBelowPeak() {
    let samples = (0..<48000).map { Float(0.5 * sin(2 * Double.pi * 100 * Double($0) / 48000)) }
    XCTAssertEqual(SoundAnalysis.rmsDB(samples), -6.0206 - 3.0103, accuracy: 0.01)
  }

  /// 無音は -inf dB とピーク無しへ落ちる（log の発散や空配列で落ちない）。
  func testSilenceIsHandled() {
    let silence = [Float](repeating: 0, count: 4800)
    XCTAssertEqual(SoundAnalysis.rmsDB(silence), -.infinity)
    XCTAssertEqual(SoundAnalysis.peakDB(silence), -.infinity)
    XCTAssertTrue(SoundAnalysis.spectralPeaks(silence, sampleRate: sampleRate, count: 5).isEmpty)
  }

  /// 最大短時間 RMS は「一番鳴っている瞬間」を測る——300 ms 窓が全長 RMS との差を生み、
  /// 窓より短い音では全長 RMS に縮退する。ラウドネス整合のトリムはこの物差しの上で測った値なので、
  /// 窓長が動くとトリム表の意味ごと変わる。
  func testMaxShortTermRMSMeasuresTheLoudestWindow() {
    // 1 秒のうち先頭 0.2 秒だけ振幅 0.5。300 ms 窓には無音が 100 ms ぶん必ず混じるので
    // -6.02 dB から 1.76 dB 下がる（窓が 150 ms なら -6.02、500 ms なら -10.00 になる）。
    var burst = [Float](repeating: 0.5, count: 9600)
    burst += [Float](repeating: 0, count: 38400)
    XCTAssertEqual(
      SoundAnalysis.maxShortTermRMSDB(burst, sampleRate: sampleRate), -7.7815, accuracy: 1e-3)
    XCTAssertEqual(SoundAnalysis.rmsDB(burst), -13.0103, accuracy: 1e-3, "全長 RMS は無音に薄まる")

    // 窓より短い音は全長 RMS に一致する。
    let short = [Float](repeating: 0.5, count: 4800)
    XCTAssertEqual(
      SoundAnalysis.maxShortTermRMSDB(short, sampleRate: sampleRate), -6.0206, accuracy: 1e-3)

    // 窓より長い無音も -inf（log の発散で落ちない）。
    XCTAssertEqual(
      SoundAnalysis.maxShortTermRMSDB([Float](repeating: 0, count: 48000), sampleRate: sampleRate),
      -.infinity)
  }

  /// 純音のスペクトル最大ピークは DFT の分解能内でその周波数に一致する。
  func testSpectralPeakFindsThePureToneFrequency() {
    let frequency = 440.0
    let samples = (0..<24000).map {
      Float(0.4 * sin(2 * Double.pi * frequency * Double($0) / 48000))
    }
    let peaks = SoundAnalysis.spectralPeaks(samples, sampleRate: sampleRate, count: 3)
    let resolution = sampleRate / 4096
    XCTAssertEqual(peaks.first?.frequency ?? 0, frequency, accuracy: resolution)
    XCTAssertEqual(peaks.first?.levelDB ?? -100, 0, accuracy: 1e-9, "最大ピークは 0 dB 基準")
  }

  /// 2 音の混合では両方がピークに立ち、相対レベルが振幅比を反映する。
  func testSpectralPeaksRankByLevel() {
    let samples = (0..<24000).map { i -> Float in
      let t = Double(i) / 48000
      return Float(
        0.4 * sin(2 * Double.pi * 440 * t) + 0.1 * sin(2 * Double.pi * 1320 * t))
    }
    let peaks = SoundAnalysis.spectralPeaks(samples, sampleRate: sampleRate, count: 3)
    let resolution = sampleRate / 4096
    XCTAssertEqual(peaks.first?.frequency ?? 0, 440, accuracy: resolution)
    guard let second = peaks.dropFirst().first else { return XCTFail("第 2 ピークが出ない") }
    XCTAssertEqual(second.frequency, 1320, accuracy: resolution)
    XCTAssertEqual(second.levelDB, 20 * log10(0.1 / 0.4), accuracy: 1.5, "振幅比 ≒ 相対レベル")
  }
}
