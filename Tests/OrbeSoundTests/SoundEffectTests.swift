import XCTest

@testable import OrbeSound

/// 後段エフェクトの性質検証。L1 純ロジック・決定論。
/// ここが崩れると、エフェクトを使う音の空間表現が案の定義と食い違ったまま鳴る。
final class SoundEffectTests: XCTestCase {
  private let sampleRate = 48000.0

  private func impulse(length: Int) -> [Double] {
    var buffer = [Double](repeating: 0, count: length)
    buffer[0] = 1
    return buffer
  }

  private func windowPeak(_ buffer: [Double], around center: Int, width: Int = 200) -> Double {
    let range = max(0, center - width)..<min(buffer.count, center + width)
    return buffer[range].map(abs).max() ?? 0
  }

  /// インパルスの繰り返しが delay 時間ごとに現れ、feedback 比で減衰する。原音は素通し。
  func testDelayEchoesDecayByFeedback() {
    var buffer = impulse(length: Int(sampleRate))
    SoundEffect.delay(time: 0.1, feedback: 0.5, damping: 20000, mix: 1)
      .apply(to: &buffer, sampleRate: sampleRate)
    XCTAssertEqual(buffer[0], 1, accuracy: 1e-12, "原音（ドライ）は変えない")
    let echo1 = windowPeak(buffer, around: 4800)
    let echo2 = windowPeak(buffer, around: 9600)
    let echo3 = windowPeak(buffer, around: 14400)
    XCTAssertGreaterThan(echo1, 0.5, "1 回目の繰り返しが立つ")
    XCTAssertEqual(echo2 / echo1, 0.5, accuracy: 0.1, "繰り返しは feedback 比で減衰")
    XCTAssertEqual(echo3 / echo2, 0.5, accuracy: 0.1)
  }

  /// mix 0 は素通し（ウェットが混ざらない）。
  func testDelayWithZeroMixIsTransparent() {
    var buffer = impulse(length: 24000)
    let original = buffer
    SoundEffect.delay(time: 0.05, feedback: 0.6, damping: 8000, mix: 0)
      .apply(to: &buffer, sampleRate: sampleRate)
    XCTAssertEqual(buffer, original)
  }

  /// damping を下げるほど繰り返しの高域が削れ、レベルも下がる（遠ざかる反響ほどこもる）。
  func testLowerDampingDarkensEchoes() {
    var bright = impulse(length: 24000)
    SoundEffect.delay(time: 0.1, feedback: 0.5, damping: 20000, mix: 1)
      .apply(to: &bright, sampleRate: sampleRate)
    var dark = impulse(length: 24000)
    SoundEffect.delay(time: 0.1, feedback: 0.5, damping: 500, mix: 1)
      .apply(to: &dark, sampleRate: sampleRate)
    XCTAssertLessThan(
      windowPeak(dark, around: 4800), windowPeak(bright, around: 4800),
      "インパルスの繰り返しは damping が低いほど鈍る")
  }

  /// 同一入力からは常に同一出力（決定論）。
  func testDelayIsDeterministic() {
    var first = impulse(length: 24000)
    var second = impulse(length: 24000)
    let effect = SoundEffect.delay(time: 0.07, feedback: 0.4, damping: 3000, mix: 0.5)
    effect.apply(to: &first, sampleRate: sampleRate)
    effect.apply(to: &second, sampleRate: sampleRate)
    XCTAssertEqual(first, second)
  }
}
