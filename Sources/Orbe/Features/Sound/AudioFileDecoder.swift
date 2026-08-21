import AVFoundation
import Foundation
import OrbeSound

/// 音声ファイルを「指定サンプルレートのモノラル `[Float]`」として読む 1 経路。
/// 取り込み（手持ちファイルのデコード）と再生（取り込み済み WAV の読み戻し）が共有する。
///
/// 対応形式は CoreAudio が読めるもの（wav / mp3 / m4a / aiff / caf 等）に委ね、Orbe 側では列挙しない
/// ——形式の一覧を持つと、OS が読めるようになったものを自前の表が拒み続ける。
enum AudioFileDecoder {
  /// 先頭 `maxSeconds` 秒までを読む（それ以上は使わないので、長大なファイルでも全長は展開しない）。
  /// 読めない・デコードできない・空は nil。
  static func monoSamples(of url: URL, sampleRate: Double, maxSeconds: Double) -> [Float]? {
    guard sampleRate > 0, let file = try? AVAudioFile(forReading: url), file.length > 0,
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: file.processingFormat, to: target)
    else { return nil }

    // 打ち切り判定は取り込み側（`SoundImport`）が行うので、上限ぴったりでなく少し余分に読む
    // ——ちょうど上限で切ると「上限を超えていた」ことが下流から見えなくなる。
    let source = file.processingFormat
    let wanted = min(Double(file.length), (maxSeconds + 1) * source.sampleRate)
    guard wanted >= 1,
      let input = AVAudioPCMBuffer(
        pcmFormat: source, frameCapacity: AVAudioFrameCount(wanted)),
      (try? file.read(into: input, frameCount: AVAudioFrameCount(wanted))) != nil,
      input.frameLength > 0
    else { return nil }

    let capacity = Double(input.frameLength) * sampleRate / source.sampleRate + 4096
    guard
      let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(capacity))
    else { return nil }
    var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = .endOfStream
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return input
    }
    guard error == nil, output.frameLength > 0, let channel = output.floatChannelData
    else { return nil }
    return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
  }
}
