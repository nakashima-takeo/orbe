import XCTest

@testable import orbe_sound

/// WAV 書き出しの生成物契約。壊れるとブラウザ / afplay が再生できない・別ピッチで鳴る・
/// 振幅が化けるのに board のカードには何も出ず、聴き比べの物差しがファイル形式の段で狂う。
final class WAVWriterTests: XCTestCase {

  private func write(_ samples: [Float], rate: Double) throws -> Data {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-sound-wav-test-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try WAVWriter.write(samples: samples, sampleRate: rate, to: url)
    return try Data(contentsOf: url)
  }

  private func uint32(_ data: Data, at offset: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << (8 * UInt32($1)) }
  }

  private func uint16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
  }

  private func tag(_ data: Data, at offset: Int) -> String {
    String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
  }

  /// ヘッダの全フィールドが 16bit PCM・モノラルを宣言し、サイズ・レートが整合する。
  func testHeaderDeclaresMono16BitPCMWithConsistentSizes() throws {
    let sampleCount = 7
    let data = try write([Float](repeating: 0.25, count: sampleCount), rate: 8000)
    let payloadBytes = UInt32(sampleCount * 2)
    XCTAssertEqual(data.count, 44 + sampleCount * 2)
    XCTAssertEqual(tag(data, at: 0), "RIFF")
    XCTAssertEqual(uint32(data, at: 4), 36 + payloadBytes)
    XCTAssertEqual(tag(data, at: 8), "WAVE")
    XCTAssertEqual(tag(data, at: 12), "fmt ")
    XCTAssertEqual(uint32(data, at: 16), 16, "fmt チャンク長")
    XCTAssertEqual(uint16(data, at: 20), 1, "PCM")
    XCTAssertEqual(uint16(data, at: 22), 1, "モノラル")
    XCTAssertEqual(uint32(data, at: 24), 8000)
    XCTAssertEqual(uint32(data, at: 28), 16000, "byte rate = rate × 2")
    XCTAssertEqual(uint16(data, at: 32), 2, "block align")
    XCTAssertEqual(uint16(data, at: 34), 16, "bits per sample")
    XCTAssertEqual(tag(data, at: 36), "data")
    XCTAssertEqual(uint32(data, at: 40), payloadBytes)
  }

  /// 小数レートのヘッダは切り捨て（8000.7 → 8000）。丸めに変えたら落ちる＝変換規則が観測面に出る。
  func testFractionalRateIsTruncatedInTheHeader() throws {
    let data = try write([0], rate: 8000.7)
    XCTAssertEqual(uint32(data, at: 24), 8000)
    XCTAssertEqual(uint32(data, at: 28), 16000)
  }

  /// ペイロードは ±1 クランプ・half-away-from-zero 丸めの 16bit リトルエンディアン。
  /// ±0.5（→ ±16384）が丸め規則の観測点、±1.5（→ ±32767）がクランプの観測点。
  func testPayloadClampsAndRoundsSamples() throws {
    let data = try write([0, 0.5, -0.5, 1, -1, 1.5, -1.5], rate: 8000)
    let payload = data[44...]
    let values = stride(from: payload.startIndex, to: payload.endIndex, by: 2).map { i in
      Int16(bitPattern: UInt16(payload[i]) | UInt16(payload[i + 1]) << 8)
    }
    XCTAssertEqual(values, [0, 16384, -16384, 32767, -32767, 32767, -32767])
  }
}
