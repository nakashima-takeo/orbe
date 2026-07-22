import XCTest

@testable import Orbe

/// `LineFramer` の行分割・持ち越し・空行スキップ・受信上限を固定する。
/// 非ブロッキング read のドレインで分割到着しても framing が壊れない契約を守る。
final class ControlLineFramerTests: XCTestCase {
  /// Outcome.lines を [String] へ。overflow なら nil。
  private func lines(_ outcome: LineFramer.Outcome) -> [String]? {
    guard case .lines(let data) = outcome else { return nil }
    return data.map { String(bytes: $0, encoding: .utf8) ?? "" }
  }

  private func bytes(_ s: String) -> Data { Data(s.utf8) }

  /// 1 回の feed に複数行 → すべて分割される。
  func testMultipleLinesInOneFeed() {
    var f = LineFramer(maxLineBytes: 1024)
    XCTAssertEqual(lines(f.feed(bytes("a\nb\nc\n"))), ["a", "b", "c"])
  }

  /// 改行をまたぐ分割 feed → 結合して 1 行になる。
  func testLineSplitAcrossFeeds() {
    var f = LineFramer(maxLineBytes: 1024)
    XCTAssertEqual(lines(f.feed(bytes("hel"))), [])
    XCTAssertEqual(lines(f.feed(bytes("lo\n"))), ["hello"])
  }

  /// 空行（連続改行）はスキップされる。
  func testEmptyLinesSkipped() {
    var f = LineFramer(maxLineBytes: 1024)
    XCTAssertEqual(lines(f.feed(bytes("a\n\n\nb\n"))), ["a", "b"])
  }

  /// 末尾に改行が無い分は持ち越され、後続の改行で確定する。
  func testTrailingPartialCarriedOver() {
    var f = LineFramer(maxLineBytes: 1024)
    XCTAssertEqual(lines(f.feed(bytes("a\npartial"))), ["a"])
    XCTAssertEqual(lines(f.feed(bytes("-rest\n"))), ["partial-rest"])
  }

  /// 改行が来ないまま残バッファが maxLineBytes を超えたら .overflow。
  func testOverflowWhenNoNewline() {
    var f = LineFramer(maxLineBytes: 8)
    XCTAssertEqual(f.feed(bytes("123456789")), .overflow)  // 9 > 8
  }

  /// ちょうど上限ぴったり（改行無し）は overflow しない（境界は超過のみ切断）。
  func testBoundaryNotOverflow() {
    var f = LineFramer(maxLineBytes: 8)
    XCTAssertEqual(lines(f.feed(bytes("12345678"))), [])  // 8 == 8、超えていない
  }

  /// 改行で確定した行は残バッファに数えない（行確定後は持ち越しのみが上限対象）。
  func testCompletedLinesDoNotCountTowardLimit() {
    var f = LineFramer(maxLineBytes: 8)
    // 長い行でも改行で確定すれば overflow しない。残りは "xy" のみ。
    XCTAssertEqual(lines(f.feed(bytes("0123456789abcdef\nxy"))), ["0123456789abcdef"])
  }
}
