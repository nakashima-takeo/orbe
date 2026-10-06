import AppKit
import XCTest

@testable import OrbeEditorCore

/// 区画の字の折り返し——行は元の文を隙間なく割り（改行は行に含めない）、どの行も幅に収まり、見え方は行の範囲に切って
/// 渡る。壊れると、スレッドの本文が区画の幅をはみ出す・選んだ範囲と写る文がずれる・インラインコードの色が別の字に付く。
final class ZoneTextLayoutTests: XCTestCase {
  private let font = NSFont.systemFont(ofSize: 12)
  private let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

  func testLinesPartitionTheTextAndFitTheWidth() {
    let string = "tail だけ見ると、間に別種のイベントが挟まったときに畳み損ねない？ merges(event) の前に種別チェックが要る気がする。"
    let styles = [ZoneTextStyle(length: string.utf16.count, font: font, color: .white)]
    let lines = ZoneTextLayout.lines(string, styles: styles, width: 160)
    XCTAssertGreaterThan(lines.count, 2)
    XCTAssertEqual(lines.first?.range.location, 0)
    for (a, b) in zip(lines, lines.dropFirst()) {
      XCTAssertEqual(NSMaxRange(a.range), b.range.location, "隙間なく続く")
    }
    XCTAssertEqual(lines.last.map { NSMaxRange($0.range) }, string.utf16.count)
    XCTAssertTrue(lines.allSatisfy { $0.width <= 160 }, "どの行も幅に収まる")
  }

  func testNewlinesAlwaysBreakAndAreNotInLines() {
    let string = "一行目\n\n三行目"
    let styles = [ZoneTextStyle(length: string.utf16.count, font: font, color: .white)]
    let lines = ZoneTextLayout.lines(string, styles: styles, width: 500)
    XCTAssertEqual(
      lines.map(\.range),
      [
        NSRange(location: 0, length: 3), NSRange(location: 4, length: 0),
        NSRange(location: 5, length: 3),
      ])
  }

  func testStylesAreSlicedToEachLine() {
    let string = "aaaa bbbb cccc"
    let styles = [
      ZoneTextStyle(length: 5, font: font, color: .white),
      ZoneTextStyle(length: 4, font: mono, color: .red),
      ZoneTextStyle(length: 5, font: font, color: .white),
    ]
    let lines = ZoneTextLayout.lines(
      string, styles: styles,
      width: ZoneTextLayout.width([
        ZoneTextRun("aaaa bbbb", font: font, color: .white)
      ]) + 1)
    XCTAssertEqual(
      lines.map(\.range), [NSRange(location: 0, length: 10), NSRange(location: 10, length: 4)],
      "行末の空白は前の行に残る")
    XCTAssertEqual(lines[0].styles.map(\.length), [5, 4, 1])
    XCTAssertEqual(lines[0].styles[1].font, mono, "インラインコードの見え方は同じ字に付く")
    XCTAssertEqual(lines[1].styles.map(\.length), [4])
  }
}
