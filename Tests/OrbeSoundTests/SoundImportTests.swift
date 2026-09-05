import XCTest

@testable import OrbeSound

/// 取り込みの信号処理（打ち切り・デクリック・ラウドネス正規化）。L1 純ロジック・決定論（音は出さない）。
/// ここが崩れると、選んだファイルが 12 案と同格に鳴らなくなる（長すぎる・音量が浮く・端でプチッと鳴る）。
final class SoundImportTests: XCTestCase {
  private let sampleRate = 48000.0

  /// 指定秒数の正弦波（振幅は dBFS でなく線形係数で指定する）。
  private func sine(seconds: Double, frequency: Double = 440, amplitude: Float = 0.3) -> [Float] {
    let count = Int(seconds * sampleRate)
    return (0..<count).map {
      amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate))
    }
  }

  /// 取り込み後の音を実際の再生と同じマスタ末尾へ通したときの最大短時間 RMS。
  private func loudness(_ processed: SoundImport.Processed) -> Double {
    SoundAnalysis.maxShortTermRMSDB(
      SoundRenderer.finalize(
        processed.samples, volume: SoundRenderer.defaultVolume, sampleRate: sampleRate),
      sampleRate: sampleRate)
  }

  // MARK: - 長さの上限

  /// 10 秒を超える入力は 10 秒で切られ、その長さが `duration` に載る。
  func testTruncatesToTheMaximumDuration() throws {
    let processed = try SoundImport.process(
      sine(seconds: SoundImport.maxDuration + 1), sampleRate: sampleRate)
    XCTAssertEqual(processed.duration, SoundImport.maxDuration, accuracy: 1e-9)
    XCTAssertEqual(processed.samples.count, Int(SoundImport.maxDuration * sampleRate))
  }

  /// 上限より短い入力はそのままの長さで通る（切らない・伸ばさない）。
  func testShorterInputKeepsItsLength() throws {
    let processed = try SoundImport.process(sine(seconds: 2), sampleRate: sampleRate)
    XCTAssertEqual(processed.duration, 2.0, accuracy: 1e-9)
  }

  /// 打ち切ったときだけ末尾 200ms がフェードする（曲の途中でぶつ切りにしない）。
  /// 短い入力の末尾は、デクリックのごく短いフェード以外そのまま残る。
  func testTruncationFadesTheTailButShortInputDoesNot() throws {
    func tailRMS(_ samples: [Float], from: Double, to: Double) -> Double {
      let range = Int(from * sampleRate)..<min(samples.count, Int(to * sampleRate))
      return SoundAnalysis.rmsDB(Array(samples[range]))
    }
    let truncated = try SoundImport.process(
      sine(seconds: SoundImport.maxDuration + 1), sampleRate: sampleRate)
    // 9.9〜10.0 秒（フェード区間）は、その直前の 0.1 秒より明確に小さい。
    XCTAssertLessThan(
      tailRMS(truncated.samples, from: 9.9, to: 10.0),
      tailRMS(truncated.samples, from: 9.7, to: 9.8) - 5, "打ち切り末尾がフェードしていない")

    let intact = try SoundImport.process(sine(seconds: 2), sampleRate: sampleRate)
    XCTAssertEqual(
      tailRMS(intact.samples, from: 1.9, to: 2.0), tailRMS(intact.samples, from: 1.7, to: 1.8),
      accuracy: 1.0, "切っていない音の末尾は落とさない")
  }

  // MARK: - デクリック

  /// 両端は常に 0 から始まり 0 で終わる（ゼロクロスで始まらないファイルのクリック防止）。
  func testDeclicksBothEnds() throws {
    // cos は先頭で最大振幅、末尾も途中で切れる＝両端とも段差になる素材。
    let count = Int(1.0 * sampleRate)
    let abrupt = (0..<count).map {
      Float(0.3 * cos(2 * Double.pi * 440 * Double($0) / sampleRate))
    }
    let processed = try SoundImport.process(abrupt, sampleRate: sampleRate)
    XCTAssertEqual(processed.samples.first ?? 1, 0, accuracy: 1e-6)
    XCTAssertEqual(processed.samples.last ?? 1, 0, accuracy: 1e-6)
    // 消すのは端だけ——中身は鳴っている。
    XCTAssertGreaterThan(processed.samples.map(abs).max() ?? 0, 0.01)
  }

  // MARK: - ラウドネス正規化（既存 24 音と同じ較正点へ揃える）

  /// 大音量でも小音量でも、マスタ末尾（既定音量）を通した後の最大短時間 RMS が
  /// カタログの整合目標へ乗る。許容は既存 24 音のラウドネステストと同じ ±0.8 dB。
  func testNormalizesLoudAndQuietInputToTheCatalogTarget() throws {
    for amplitude: Float in [0.9, 0.3, 0.01, 0.001] {
      let processed = try SoundImport.process(
        sine(seconds: 2, amplitude: amplitude), sampleRate: sampleRate)
      XCTAssertEqual(
        loudness(processed), SoundCatalog.loudnessTargetDB, accuracy: 0.8,
        "振幅 \(amplitude) の正規化が目標から外れている")
    }
  }

  /// 波形の性格（打撃的な音）が変わっても同じ目標へ乗る。
  func testNormalizesPercussiveInput() throws {
    let count = Int(1.5 * sampleRate)
    let clicks = (0..<count).map { i -> Float in
      let phase = Double(i % Int(0.3 * sampleRate)) / sampleRate
      let decay = exp(-phase * 40)
      return Float(0.8 * decay * sin(2 * Double.pi * 900 * phase))
    }
    let processed = try SoundImport.process(clicks, sampleRate: sampleRate)
    XCTAssertEqual(loudness(processed), SoundCatalog.loudnessTargetDB, accuracy: 0.8)
  }

  // MARK: - 無音

  /// 完全な無音は取り込めない（エラーで弾く）。
  func testSilentInputFails() {
    XCTAssertThrowsError(
      try SoundImport.process([Float](repeating: 0, count: Int(sampleRate)), sampleRate: sampleRate)
    ) { XCTAssertEqual($0 as? SoundImport.Failure, .silent) }
  }

  /// 空の入力も同じく弾く。
  func testEmptyInputFails() {
    XCTAssertThrowsError(try SoundImport.process([], sampleRate: sampleRate)) {
      XCTAssertEqual($0 as? SoundImport.Failure, .silent)
    }
  }

  /// 非有限値（float の WAV/AIFF/CAF は NaN/Inf を表現できる）が混ざった入力は、実音があれば
  /// 取り込めて出力に非有限値を残さない。1 個でも通すとマスタ末尾のコンプレッサの帰還が固着し、
  /// そこから末尾までの全サンプルが NaN になる——先頭に来た場合は逆に、実音があるのに
  /// 「音が入っていない」として弾かれる。どちらも入口で潰すことで閉じる。
  func testNonFiniteSamplesAreNeutralizedNotPropagated() throws {
    for index in [0, 24000, Int(1.5 * sampleRate) - 1] {
      for bad: Float in [.nan, .infinity, -.infinity] {
        var input = sine(seconds: 1.5)
        input[index] = bad
        let processed = try SoundImport.process(input, sampleRate: sampleRate)
        XCTAssertTrue(
          processed.samples.allSatisfy(\.isFinite), "取り込み後に非有限値が残っている (\(index)/\(bad))")
        let finalized = SoundRenderer.finalize(
          processed.samples, volume: SoundRenderer.defaultVolume, sampleRate: sampleRate)
        XCTAssertTrue(
          finalized.allSatisfy(\.isFinite), "マスタ末尾で非有限値が伝播した (\(index)/\(bad))")
      }
    }
  }

  /// 持ち上げ切れない雑音底（目標より 60 dB 以上下）は「音が入っていない」として弾く。
  func testNoiseFloorOnlyInputFails() {
    XCTAssertThrowsError(
      try SoundImport.process(sine(seconds: 1, amplitude: 1e-7), sampleRate: sampleRate)
    ) { XCTAssertEqual($0 as? SoundImport.Failure, .silent) }
  }

  // MARK: - 決定論

  /// 同じ入力からは常に同じ結果（二分探索も含めて決定論）。
  func testProcessIsDeterministic() throws {
    let input = sine(seconds: 3, amplitude: 0.42)
    let first = try SoundImport.process(input, sampleRate: sampleRate)
    let second = try SoundImport.process(input, sampleRate: sampleRate)
    XCTAssertEqual(first, second)
  }
}
