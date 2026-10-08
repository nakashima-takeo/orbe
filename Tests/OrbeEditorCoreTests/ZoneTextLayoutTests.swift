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

  /// 見え方ごとの x 範囲は字にぴったり（前の字の後ろの空白を含まない）。余白は前後の字をその幅ずつ押し出し、範囲には
  /// 含めない。行頭の見え方の余白は行の字を右へ寄せる。
  func testSpansHugTheGlyphsAndPaddingPushesTheNeighbours() {
    let string = "see code here"
    let styles = { (padding: CGFloat) in
      [
        ZoneTextStyle(length: 4, font: self.font, color: .white),
        ZoneTextStyle(length: 4, font: self.mono, color: .red, padding: padding),
        ZoneTextStyle(length: 5, font: self.font, color: .white),
      ]
    }
    let bare = ZoneTextLayout.lines(string, styles: styles(0), width: 500)[0]
    let padded = ZoneTextLayout.lines(string, styles: styles(4), width: 500)[0]
    let lead = CGFloat(
      CTLineGetTypographicBounds(
        ZoneTextLayout.typeset(
          "see ", styles: [ZoneTextStyle(length: 4, font: font, color: .white)]
        ).line, nil, nil, nil))
    XCTAssertGreaterThan(
      lead, ZoneTextLayout.width([ZoneTextRun("see", font: font, color: .white)]),
      "前提: 手前の空白に幅がある")
    let code = ZoneTextLayout.width([ZoneTextRun("code", font: mono, color: .red)])
    XCTAssertEqual(bare.spans[1].lowerBound, lead, accuracy: 0.01, "空白の後ろから")
    XCTAssertEqual(bare.spans[1].upperBound - bare.spans[1].lowerBound, code, accuracy: 0.01)
    XCTAssertEqual(padded.spans[1].lowerBound, lead + 4, accuracy: 0.01, "前の余白の分右")
    XCTAssertEqual(padded.spans[1].upperBound - padded.spans[1].lowerBound, code, accuracy: 0.01)
    XCTAssertEqual(padded.spans[2].lowerBound, bare.spans[2].lowerBound + 8, accuracy: 0.01)
    XCTAssertEqual(padded.width, bare.width + 8, accuracy: 0.01)
    let leading = ZoneTextLayout.lines(
      "code", styles: [ZoneTextStyle(length: 4, font: mono, color: .red, padding: 4)], width: 500)[
        0]
    XCTAssertEqual(leading.spans[0].lowerBound, 4, accuracy: 0.01, "行頭の余白で右へ")
    XCTAssertEqual(leading.width, 4 + code + 4, accuracy: 0.01)
  }

  /// 折り返しで割れた見え方は、割れた側の余白を持たない。
  func testPaddingIsDroppedOnTheSideCutByAWrap() {
    let style = ZoneTextStyle(length: 10, font: mono, color: .red, padding: 4)
    let head = ZoneTextLayout.styles([style], in: NSRange(location: 0, length: 6))[0]
    let tail = ZoneTextLayout.styles([style], in: NSRange(location: 6, length: 4))[0]
    XCTAssertEqual([head.leadingPadding, head.trailingPadding], [4, 0])
    XCTAssertEqual([tail.leadingPadding, tail.trailingPadding], [0, 4])
  }

  /// 組んだ字の連なりは見え方の境で分かれる（同じ字体でも）。
  func testTypesetRunsSplitAtEveryStyle() {
    let set = ZoneTextLayout.typeset(
      "redgreen",
      styles: [
        ZoneTextStyle(length: 3, font: font, color: .red),
        ZoneTextStyle(length: 5, font: font, color: .green),
      ])
    let runs = CTLineGetGlyphRuns(set.line) as? [CTRun] ?? []
    XCTAssertEqual(runs.map { ZoneTextLayout.style(of: $0) }, [0, 1])
  }
}
