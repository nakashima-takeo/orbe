import AppKit
import XCTest

@testable import OrbeEditorCore

/// 絵の差し込みの字の折り返し——行は元の文を隙間なく割り（改行は行に含めない）、どの行も幅に収まり、見え方は行の範囲に
/// 切って渡る。壊れると、スレッドの本文が絵の差し込みの幅をはみ出す・選んだ範囲と写る文がずれる・インラインコードの色が
/// 別の字に付く。
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
          "see ", range: NSRange(location: 0, length: 4),
          styles: [ZoneTextStyle(length: 4, font: font, color: .white)]
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

  /// 余白は、組版で 1 つにまとまる字（ZWJ でつないだ絵文字・タミルの合字・基の字と別のグリフで描くタイ文字の結合記号）を
  /// 割らず、その外に付く。右から左の字のインラインコードでも、余白はコードの字の中ではなく見た目の左右に出る。どの場合も、
  /// 余白なしで組んだ行と字の数が同じで、コードの字の幅は変わらず、コードは左の余白の分、後ろの字は左右の余白の分だけ右へ
  /// ずれる。
  func testPaddingStaysOutsideClustersAndOnTheVisualSides() {
    let cases = [
      ("ZWJ でつないだ絵文字", "👨‍👩‍👧", "👨‍👩‍👧"), ("タミルの合字", "க்ஷ", "க்ஷ"), ("タイ文字の結合記号", "see ", "กี่"),
      ("右から左の字", "see ", "שלום"),
    ]
    let padding: CGFloat = 4
    for (name, before, code) in cases {
      let string = before + code + " z"
      let styles = { (padding: CGFloat) in
        [
          ZoneTextStyle(length: before.utf16.count, font: self.font, color: .white),
          ZoneTextStyle(length: code.utf16.count, font: self.mono, color: .red, padding: padding),
          ZoneTextStyle(length: 2, font: self.font, color: .white),
        ]
      }
      let bare = ZoneTextLayout.lines(string, styles: styles(0), width: 500)[0]
      let padded = ZoneTextLayout.lines(string, styles: styles(padding), width: 500)[0]
      XCTAssertEqual(
        glyphCount(string, styles(padding)), glyphCount(string, styles(0)), "\(name): 字を割らない")
      XCTAssertEqual(padded.width, bare.width + 2 * padding, accuracy: 0.01, "\(name): 幅は余白の分だけ増える")
      XCTAssertEqual(
        padded.spans[1].upperBound - padded.spans[1].lowerBound,
        bare.spans[1].upperBound - bare.spans[1].lowerBound, accuracy: 0.01,
        "\(name): コードの字の幅は変わらない")
      XCTAssertEqual(
        padded.spans[1].lowerBound, bare.spans[1].lowerBound + padding, accuracy: 0.01,
        "\(name): コードは左の余白の分右")
      XCTAssertEqual(
        padded.spans[2].lowerBound, bare.spans[2].lowerBound + 2 * padding, accuracy: 0.01,
        "\(name): 後ろの字は左右の余白の分右")
    }
  }

  private func glyphCount(_ string: String, _ styles: [ZoneTextStyle]) -> Int {
    CTLineGetGlyphCount(
      ZoneTextLayout.typeset(
        string, range: NSRange(location: 0, length: string.utf16.count), styles: styles
      ).line)
  }

  /// 余白のあるインラインコードと右から左の字が同じ段落にあっても、折り返したどの行も幅に収まる。
  func testWrappedLinesFitTheWidthWithPaddedCodeAndRightToLeftText() {
    for parts in [
      ["see the ", "קוד ארוך", " and more words here"],
      ["הריצו את ", "git commit -m", " ואז את זה"],
    ] {
      let string = parts.joined()
      let over = stride(from: CGFloat(40), through: 200, by: 0.5).filter { width in
        ZoneTextLayout.lines(string, styles: codeStyles(parts), width: width).contains {
          $0.width > width
        }
      }
      XCTAssertEqual(over, [], "\(string) を折り返すと幅を超える行が出る幅")
    }
  }

  /// 段落の向きに依らず、折り返したどの行でも、インラインコードの余白は、同じ行にある前後の字とコードの間に入り、地は行の
  /// 中に収まって前後の字にかぶらない（→ `misplacedPadding(_:)`）。右から左の字で始まる段落と、右から左の字のコードが
  /// 折り返す段落で、コードの後ろが段落と同じ向きの字のときに確かめる。
  func testCodePaddingSitsBetweenTheCodeAndItsNeighboursOnEveryLine() {
    for parts in [
      ["שלום עולם ", "aaaa bbbb cccc dddd", " עולם"], ["see ", "שלום עולם ארוך מאוד", " z"],
    ] {
      XCTAssertEqual(misplacedPadding(parts), [], "\(parts.joined()) を折り返したとき、余白か地の置き場が違う行")
    }
  }

  /// コードの後ろがコードと同じ向き（段落と逆の向き）の字で、コードの終わりとその字が同じ行に並ぶと、末尾の余白は段落の
  /// 向きで決めた側（コードの続きが前の行から来る、割れた側）に付き、後ろの字はコードの地に接する。あるべき振る舞いは、
  /// 余白がコードと後ろの字の間に入ること。
  func testCodePaddingSitsBetweenTheCodeAndAFollowingRunOfTheSameDirection() {
    XCTExpectFailure("末尾の余白の左右を、コードの字の並びの向きでなく段落の向きで決めている") {
      for parts in [
        ["שלום עולם ", "aaaa bbbb cccc dddd", " z"], ["see ", "שלום עולם ארוך מאוד", " עולם"],
      ] {
        XCTAssertEqual(misplacedPadding(parts), [], "\(parts.joined()) を折り返したとき、余白か地の置き場が違う行")
      }
    }
  }

  /// 前と後ろを本文の字体、真ん中を余白 4 のインラインコードにした文 `parts` を幅 60〜200 で折り返し、コードの余白か地の
  /// 置き場が違う行を返す。正しい行では、地（字の x 範囲を余白の分広げたもの）は行の中に収まり、同じ行にある前後の字と
  /// コードの間にその側の余白が入り、地は前後の字にかぶらない——余白はコードの見た目の外側に付き、折り返しで割れた側には
  /// 付かない。
  private func misplacedPadding(_ parts: [String]) -> [String] {
    var wrong: [String] = []
    for width in stride(from: CGFloat(60), through: 200, by: 0.5) {
      for line in ZoneTextLayout.lines(parts.joined(), styles: codeStyles(parts), width: width) {
        guard let code = line.styles.firstIndex(where: { $0.font == mono }),
          !line.spans[code].isEmpty
        else { continue }
        let (glyphs, ground) = (line.spans[code], line.ground(code))
        let inside = ground.lowerBound >= -0.01 && ground.upperBound <= line.width + 0.01
        let neighbours = [
          (code - 1, line.styles[code].leadingPadding),
          (code + 1, line.styles[code].trailingPadding),
        ]
        let spaced = neighbours.allSatisfy { other, padding in
          guard line.spans.indices.contains(other), !line.spans[other].isEmpty else { return true }
          let span = line.spans[other]
          let gap = max(span.lowerBound - glyphs.upperBound, glyphs.lowerBound - span.upperBound)
          let apart =
            ground.upperBound <= span.lowerBound + 0.01
            || span.upperBound <= ground.lowerBound + 0.01
          return gap >= padding - 0.01 && apart
        }
        if !inside || !spaced { wrong.append("幅 \(width) の行 \(line.range) の地 \(ground)") }
      }
    }
    return wrong
  }

  /// 段落の途中の行も段落の向きで組む——左から右の段落で右から左の字から始まる行でも、後ろの字はその右に、右から左の
  /// 段落で左から右の字から始まる行でも、後ろの字はその左に並ぶ。
  func testAWrappedLineIsLaidOutInTheParagraphsDirection() throws {
    for (parts, width, rightToLeft) in [
      (["see ", "שלום עולם ארוך מאוד", " z"], CGFloat(90), false),
      (["שלום ", "aaaa bbbb cccc dddd", " עולם"], 90, true),
    ] {
      let string = parts.joined()
      let lines = ZoneTextLayout.lines(string, styles: codeStyles(parts), width: width)
      let line = try XCTUnwrap(
        lines.last { $0.range.location > 0 && $0.styles.count == 2 && $0.styles[0].font == mono },
        "前提: \(string) に、コードの続きから始まって後ろの字が並ぶ行がある")
      let (code, after) = (line.spans[0], line.spans[1])
      if rightToLeft {
        XCTAssertLessThanOrEqual(after.upperBound, code.lowerBound + 0.01, "\(string): 後ろの字は左")
      } else {
        XCTAssertGreaterThanOrEqual(after.lowerBound, code.upperBound - 0.01, "\(string): 後ろの字は右")
      }
    }
  }

  /// 前と後ろを本文の字体、真ん中を余白 4 のインラインコードにした見え方。
  private func codeStyles(_ parts: [String]) -> [ZoneTextStyle] {
    parts.enumerated().map { index, part in
      index == 1
        ? ZoneTextStyle(length: part.utf16.count, font: mono, color: .red, padding: 4)
        : ZoneTextStyle(length: part.utf16.count, font: font, color: .white)
    }
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
      "redgreen", range: NSRange(location: 0, length: 8),
      styles: [
        ZoneTextStyle(length: 3, font: font, color: .red),
        ZoneTextStyle(length: 5, font: font, color: .green),
      ])
    let runs = CTLineGetGlyphRuns(set.line) as? [CTRun] ?? []
    XCTAssertEqual(runs.map { ZoneTextLayout.style(of: $0) }, [0, 1])
  }
}
