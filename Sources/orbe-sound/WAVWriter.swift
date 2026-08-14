import Foundation

/// 最小の RIFF/WAVE 書き出し（16bit PCM・モノラル）。制作ループの試聴・受け渡し用で、
/// 合成の純 DSP 層（OrbeSound）には持ち込まない。
enum WAVWriter {
  static func write(samples: [Float], sampleRate: Double, to url: URL) throws {
    var data = Data()
    func append(_ tag: String) { data.append(contentsOf: tag.utf8) }
    func append32(_ value: UInt32) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func append16(_ value: UInt16) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    let payloadBytes = UInt32(samples.count * 2)
    let rate = UInt32(sampleRate)
    append("RIFF")
    append32(36 + payloadBytes)
    append("WAVE")
    append("fmt ")
    append32(16)  // fmt チャンク長
    append16(1)  // PCM
    append16(1)  // モノラル
    append32(rate)
    append32(rate * 2)  // byte rate（16bit × 1ch）
    append16(2)  // block align
    append16(16)  // bits per sample
    append("data")
    append32(payloadBytes)
    for sample in samples {
      let clamped = max(-1, min(1, sample))
      let value = Int16((clamped * 32767).rounded())
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    try data.write(to: url)
  }
}
