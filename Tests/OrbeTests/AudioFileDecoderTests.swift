import AVFoundation
import OrbeSound
import XCTest

@testable import Orbe

/// 音声ファイルの読み戻し（`AudioFileDecoder`）。**実ファイルを書いて読む**——ここは
/// パレット側のテストが seam で差し替えている実体そのもので、差し替えたままでは 1 行も走らない。
///
/// 押さえるのは「入力を 1 フレームも落とさないこと」。末尾が落ちると、取り込み時に掛けた
/// デクリックのフェードごと捨てられ、防いだはずのクリックが再生経路で復活する。
final class AudioFileDecoderTests: OrbeTestCase {
  private let storageRate = 48000.0

  // MARK: - 素材

  /// `seconds` 秒の正弦波。末尾がゼロ交差で終わらない長さを選べば、フェードの有無が末尾の値に出る。
  private func sine(seconds: Double, sampleRate: Double, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(seconds * sampleRate)).map {
      amplitude * Float(sin(2 * Double.pi * 440 * Double($0) / sampleRate))
    }
  }

  /// 隔離ディレクトリへ WAV を 1 枚書く（`channels` 分は同じ列を複製する）。
  private func writeWAV(
    _ samples: [Float], sampleRate: Double, channels: AVAudioChannelCount = 1, named name: String
  ) throws -> URL {
    let url = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent(name)
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels,
        interleaved: false))
    let file = try AVAudioFile(
      forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
      interleaved: false)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let channelData = try XCTUnwrap(buffer.floatChannelData)
    samples.withUnsafeBufferPointer { source in
      guard let base = source.baseAddress else { return }
      for channel in 0..<Int(channels) {
        channelData[channel].update(from: base, count: source.count)
      }
    }
    try file.write(from: buffer)
    return url
  }

  private func read(_ url: URL, at sampleRate: Double) throws -> [Float] {
    try XCTUnwrap(
      AudioFileDecoder.monoSamples(
        of: url, sampleRate: sampleRate, maxSeconds: SoundImport.maxDuration))
  }

  /// 末尾サンプルの、ピークに対する大きさ（クリックの段差の物差し）。
  private func tailRatio(_ samples: [Float]) -> Float {
    let peak = samples.map(abs).max() ?? 0
    guard peak > 0 else { return 0 }
    return abs(samples[samples.count - 1]) / peak
  }

  // MARK: - フレームを落とさない

  /// 同じサンプルレートで読み戻せば、フレーム数も値も保存した実体と**そのまま**一致する。
  /// コンバータを 1 回の `convert` で打ち切ると末尾が落ちる（実測 640 フレーム＝13.3 ms）。
  func testSameRateReadBackKeepsEveryFrame() throws {
    let written = sine(seconds: 3, sampleRate: storageRate)  // 144000 フレーム
    let url = try writeWAV(written, sampleRate: storageRate, named: "same-rate.wav")

    let read = try read(url, at: storageRate)
    XCTAssertEqual(read.count, written.count, "読み戻しでフレームが落ちている")
    XCTAssertEqual(
      zip(read, written).map { abs($0 - $1) }.max() ?? 0, 0, accuracy: 1e-6, "値も変わらない")
  }

  /// 出力デバイスが 44.1 kHz でも、リサンプル比どおりの長さが出る（末尾だけ欠けたりしない）。
  func testResampledReadBackKeepsTheWholeTail() throws {
    let written = sine(seconds: 3, sampleRate: storageRate)
    let url = try writeWAV(written, sampleRate: storageRate, named: "resample.wav")

    let read = try read(url, at: 44100)
    XCTAssertEqual(
      Double(read.count), Double(written.count) * 44100 / storageRate, accuracy: 64,
      "リサンプル後の長さが比と合わない")
  }

  /// ステレオ素材もモノラルへ畳んだうえでフレーム数を保つ（取り込み経路が通る道）。
  func testStereoSourceIsMixedDownWithoutLosingFrames() throws {
    let written = sine(seconds: 1, sampleRate: storageRate)
    let url = try writeWAV(written, sampleRate: storageRate, channels: 2, named: "stereo.wav")

    XCTAssertEqual(try read(url, at: storageRate).count, written.count)
  }

  /// 上限より十分長い素材でも読むのは上限＋余白まで（全長は展開しない）。余白を残すのは、
  /// 「上限を超えていた」ことを取り込み側の打ち切り判定から見えるようにするため。
  func testLongSourceIsReadOnlyUpToTheLimitPlusMargin() throws {
    let url = try writeWAV(
      sine(seconds: SoundImport.maxDuration + 5, sampleRate: storageRate), sampleRate: storageRate,
      named: "long.wav")

    let read = try read(url, at: storageRate)
    XCTAssertGreaterThan(Double(read.count) / storageRate, SoundImport.maxDuration, "打ち切り判定に足りる")
    XCTAssertLessThanOrEqual(
      Double(read.count) / storageRate, SoundImport.maxDuration + 1.1, "全長は展開しない")
  }

  // MARK: - 取り込み → 読み戻しの往復（クリックが復活しないこと）

  /// 取り込んだ実体を再生経路と同じ手順で読み戻すと、フレーム数は取り込み時に測った長さと一致し、
  /// 末尾はデクリックのフェード後の十分小さい値になる。
  ///
  /// これがこのファイルの本題。読み戻しが末尾を落とすと、フェードごと捨てられて最終サンプルが
  /// ピークの 7 割という段差になり、鳴らすたびにプチッと鳴る（合成音の末尾はピークの 0.1% 以下）。
  func testImportedFileReadsBackWithItsDeclickFadeIntact() throws {
    let url = try writeWAV(
      sine(seconds: 3, sampleRate: storageRate), sampleRate: storageRate,
      named: "source.wav")
    guard case .success(let imported) = SoundFileImporter.importFile(at: url) else {
      return XCTFail("取り込みに失敗した")
    }
    let stored = try XCTUnwrap(CustomSoundStore.url(for: imported.file))

    for rate in [storageRate, 44100.0] {
      let read = try read(stored, at: rate)
      XCTAssertEqual(
        Double(read.count), imported.duration * rate, accuracy: 64,
        "\(rate) Hz の読み戻しが取り込み時の長さと合わない")
      XCTAssertLessThan(
        tailRatio(read), 0.01, "\(rate) Hz の読み戻しで末尾のフェードが落ちている（クリックが鳴る）")
    }
  }

  /// 打ち切りが起きた取り込み（10 秒超）でも同じ——末尾 200ms のフェードが読み戻しに残る。
  func testTruncatedImportReadsBackWithItsFadeIntact() throws {
    let url = try writeWAV(
      sine(seconds: SoundImport.maxDuration + 3, sampleRate: storageRate), sampleRate: storageRate,
      named: "long-source.wav")
    guard case .success(let imported) = SoundFileImporter.importFile(at: url) else {
      return XCTFail("取り込みに失敗した")
    }
    XCTAssertEqual(imported.duration, SoundImport.maxDuration, accuracy: 1e-9)

    let read = try read(try XCTUnwrap(CustomSoundStore.url(for: imported.file)), at: storageRate)
    XCTAssertEqual(read.count, Int(SoundImport.maxDuration * storageRate))
    XCTAssertLessThan(tailRatio(read), 0.01)
  }

  // MARK: - 読めないもの

  /// 音声でないファイル・不在のファイルは nil（再生層はここで紋章の同 event 音へ退避する）。
  func testUnreadableFilesYieldNil() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let garbage = dir.appendingPathComponent("not-audio.wav")
    try Data("this is not audio".utf8).write(to: garbage)
    XCTAssertNil(
      AudioFileDecoder.monoSamples(
        of: garbage, sampleRate: storageRate, maxSeconds: SoundImport.maxDuration))
    XCTAssertNil(
      AudioFileDecoder.monoSamples(
        of: dir.appendingPathComponent("missing.wav"), sampleRate: storageRate,
        maxSeconds: SoundImport.maxDuration))
  }
}
