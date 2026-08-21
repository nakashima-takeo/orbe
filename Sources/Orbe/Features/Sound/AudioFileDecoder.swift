import AVFoundation
import Foundation
import OrbeSound

/// 音声ファイルを「指定サンプルレートのモノラル `[Float]`」として読む 1 経路。
/// 取り込み（手持ちファイルのデコード）と再生（取り込み済み WAV の読み戻し）が共有する。
///
/// 対応形式は CoreAudio が読めるもの（wav / mp3 / m4a / aiff / caf 等）に委ね、Orbe 側では列挙しない
/// ——形式の一覧を持つと、OS が読めるようになったものを自前の表が拒み続ける。
enum AudioFileDecoder {
  /// 1 回のファイル読みで受け取るフレーム数の上限。`AVAudioFile.read` は要求したぶんを**必ずしも
  /// 返さない**（内部のパケット境界で短く返る）ので、この値は「1 度に頼む量」でしかなく、
  /// 取りこぼしを防ぐのは EOF まで読み続ける下のループのほう。
  private static let readBlockFrames: AVAudioFrameCount = 16384

  /// 1 回の `convert` で受け取る出力フレーム数。同じく値そのものに意味は無い。
  private static let outputBlockFrames: AVAudioFrameCount = 16384

  /// 先頭 `maxSeconds` 秒までを読む（それ以上は使わないので、長大なファイルでも全長は展開しない）。
  /// 読めない・デコードできない・空は nil。
  ///
  /// ファイルを 1 塊に読んでから 1 度だけ変換する形は**採れない**。`AVAudioFile.read` は 1 回の
  /// 呼び出しで要求フレーム数に届かないことがあり（実測: 144000 フレームを頼んで 143360＝640 フレーム
  /// 不足）、`AVAudioConverter` もまた 1 回の `convert` で内部の残りを出し切るとは限らない。
  /// どちらも「足りなかったぶんは次の呼び出しで返す」設計なので、**両方を尽きるまで回す**のが
  /// 唯一の正しい形になる。落ちるのは常に末尾なので、取り込み時に掛けたデクリックのフェードごと
  /// 捨てられ、防いだはずのクリックが再生のたびに鳴る——余分に確保する・フェードを伸ばすといった
  /// 帳尻合わせでは、入力を落としているという事実そのものが残る。
  static func monoSamples(of url: URL, sampleRate: Double, maxSeconds: Double) -> [Float]? {
    guard sampleRate > 0, let file = try? AVAudioFile(forReading: url), file.length > 0,
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: file.processingFormat, to: target)
    else { return nil }

    // 打ち切り判定は取り込み側（`SoundImport`）が行うので、上限ぴったりでなく少し余分に供給する
    // ——ちょうど上限で切ると「上限を超えていた」ことが下流から見えなくなる。
    let source = file.processingFormat
    let limit = AVAudioFrameCount(min(Double(file.length), (maxSeconds + 1) * source.sampleRate))
    guard limit >= 1,
      let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: readBlockFrames)
    else { return nil }

    var samples: [Float] = []
    samples.reserveCapacity(Int(Double(limit) * sampleRate / source.sampleRate) + 1)
    var fed: AVAudioFrameCount = 0

    while true {
      guard let chunk = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputBlockFrames) else {
        return nil
      }
      var error: NSError?
      // コンバータが入力を欲しがるたびファイルから 1 ブロック読んで渡す。上限に達した／EOF を踏んだ
      // ら `.endOfStream` を返し、「もう来ない」と伝えてコンバータに残りを吐き出させる。
      let status = converter.convert(to: chunk, error: &error) { _, inputStatus in
        let remaining = limit - fed
        guard remaining > 0,
          (try? file.read(into: input, frameCount: min(remaining, input.frameCapacity))) != nil,
          input.frameLength > 0
        else {
          inputStatus.pointee = .endOfStream
          return nil
        }
        fed += input.frameLength
        inputStatus.pointee = .haveData
        return input
      }
      if let channel = chunk.floatChannelData, chunk.frameLength > 0 {
        samples.append(
          contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(chunk.frameLength)))
      }
      switch status {
      case .haveData where chunk.frameLength > 0: continue  // まだ出る
      case .error: return nil
      default: break  // endOfStream / 出力が出なくなった（進まないなら止める）
      }
      break
    }
    return samples.isEmpty ? nil : samples
  }
}
