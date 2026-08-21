import AVFoundation
import Foundation
import OrbeSound

/// 手持ちの音声ファイルを通知音として**取り込む**（デコード → 打ち切り・正規化 → アプリ領域へ保存）。
///
/// 取り込んだ後は元ファイルを一切見ない。だから設定は「外の可変な世界」に依存せず、ファイルを
/// 移動・改名・削除しても鳴り続ける——12 案が「アプリが持っている音」であるのと同じ性質になる。
/// 差し替えたければ選び直す（新しい名前で書き、値ごと置き換わる）。
enum SoundFileImporter {
  /// 取り込めなかった理由。**選んだその場で**ユーザーへ伝えるためにあり、鳴らす瞬間まで
  /// 失敗が分からない状態を作らない。
  enum ImportError: Error, Equatable {
    /// 読めない・デコードできない（形式・破損）。
    case unreadable
    /// 音が入っていない（無音・雑音底しかない）。
    case silent
  }

  /// 取り込みの全長は 48 kHz モノラルで揃える（保存形式が 1 つなら、再生側の読み戻しも 1 通り）。
  private static let storageSampleRate = 48000.0

  static func importFile(at url: URL) -> Result<CustomSoundSource, ImportError> {
    guard
      let decoded = AudioFileDecoder.monoSamples(
        of: url, sampleRate: storageSampleRate, maxSeconds: SoundImport.maxDuration)
    else { return .failure(.unreadable) }
    guard
      let processed = try? SoundImport.process(decoded, sampleRate: storageSampleRate)
    else { return .failure(.silent) }
    guard let file = write(processed.samples) else { return .failure(.unreadable) }
    return .success(
      CustomSoundSource(
        file: file, name: url.lastPathComponent, duration: processed.duration))
  }

  /// 48 kHz モノラル Float32 の WAV として一意名で書き、その相対名を返す。
  private static func write(_ samples: [Float]) -> String? {
    let name = CustomSoundStore.newFileName()
    guard !samples.isEmpty, let destination = CustomSoundStore.url(for: name),
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: storageSampleRate, channels: 1,
        interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      guard let base = source.baseAddress else { return }
      channel[0].update(from: base, count: source.count)
    }
    guard
      let file = try? AVAudioFile(
        forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32,
        interleaved: false),
      (try? file.write(from: buffer)) != nil
    else {
      try? FileManager.default.removeItem(at: destination)  // 書きかけを残さない
      return nil
    }
    return name
  }
}
