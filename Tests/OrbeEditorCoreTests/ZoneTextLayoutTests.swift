import AppKit
import XCTest

@testable import OrbeEditorCore

/// 絵の差し込みの字の折り返し——行は元の文を隙間なく割り（改行は行に含めない）、どの行も幅に収まり、見え方の地は行ごとに
/// 字に合う。壊れると、スレッドの本文が絵の差し込みの幅をはみ出す・選んだ範囲と写る文がずれる・インラインコードの地が別の
/// 字に付く。
final class ZoneTextLayoutTests: XCTestCase {
  let font = NSFont.systemFont(ofSize: 12)
  let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  let padding: CGFloat = 4

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

  /// 行末の空白は前の行に残り、見え方の地はその見え方の字がある行にだけある。
  func testSpansBelongToTheLinesThatHoldTheirGlyphs() {
    let string = "aaaa bbbb cccc"
    let styles = [
      ZoneTextStyle(length: 5, font: font, color: .white),
      ZoneTextStyle(length: 4, font: mono, color: .red),
      ZoneTextStyle(length: 5, font: font, color: .white),
    ]
    let lines = ZoneTextLayout.lines(
      string, styles: styles,
      width: ZoneTextLayout.width([ZoneTextRun("aaaa bbbb", font: font, color: .white)]) + 1)
    XCTAssertEqual(
      lines.map(\.range), [NSRange(location: 0, length: 10), NSRange(location: 10, length: 4)],
      "行末の空白は前の行に残る")
    XCTAssertEqual(lines[0].spans(of: 1).count, 1)
    XCTAssertEqual(lines[1].spans(of: 1), [])
    XCTAssertEqual(lines[1].spans(of: 2).count, 1)
  }

  /// コードの地は字に余白の幅を足した範囲で、余白は前後の字をその幅ずつ押し出す。行頭のコードの余白は字を右へ寄せる。
  func testPaddingPushesTheNeighboursAndWidensTheGround() throws {
    let parts = ["see ", "code", " here"]
    let bare = try XCTUnwrap(
      ZoneTextLayout.lines(parts.joined(), styles: styles(parts, padding: 0), width: 500).first)
    let padded = try XCTUnwrap(
      ZoneTextLayout.lines(parts.joined(), styles: styles(parts, padding: 4), width: 500).first)
    let code = try XCTUnwrap(glyphs(of: 1, in: padded))
    let ground = try XCTUnwrap(padded.spans(of: 1).first)
    XCTAssertEqual(ground.lowerBound, code.lowerBound - 4, accuracy: 0.01)
    XCTAssertEqual(ground.upperBound, code.upperBound + 4, accuracy: 0.01)
    XCTAssertEqual(
      code.lowerBound, try XCTUnwrap(glyphs(of: 1, in: bare)).lowerBound + 4, accuracy: 0.01)
    XCTAssertEqual(
      try XCTUnwrap(glyphs(of: 2, in: padded)).lowerBound,
      try XCTUnwrap(glyphs(of: 2, in: bare)).lowerBound + 8, accuracy: 0.01)
    XCTAssertEqual(padded.width, bare.width + 8, accuracy: 0.01)
    let leading = try XCTUnwrap(
      ZoneTextLayout.lines(
        "code", styles: [ZoneTextStyle(length: 4, font: mono, color: .red, padding: 4)],
        width: 500
      ).first)
    XCTAssertEqual(try XCTUnwrap(glyphs(of: 0, in: leading)).lowerBound, 4, accuracy: 0.01)
    XCTAssertEqual(
      leading.width,
      ZoneTextLayout.width([ZoneTextRun("code", font: mono, color: .red)]) + 8, accuracy: 0.01)
  }

  /// 余白は、組版で 1 つにまとまる字（ZWJ でつないだ絵文字・タミルの合字・基の字と別のグリフで描く結合記号）を割らず、
  /// 1 字を 2 つのグリフで描くタイ語の ำ・ラオ語の ຳ でも字の間に隙間を作らない。どの場合も、描くグリフの数は余白なしと
  /// 同じで、コードの字の幅は変わらない。
  func testPaddingNeverSplitsAClusterOrAGlyphPair() throws {
    let cases = [
      ("ZWJ でつないだ絵文字", "👨‍👩‍👧"), ("タミルの合字", "க்ஷ"), ("タイ文字の結合記号", "กี่"), ("タイ語の ำ", "กำ"),
      ("ラオ語の ຳ", "ກຳ"), ("右から左の字", "שלום"),
    ]
    for (name, code) in cases {
      let parts = ["see ", code, " z"]
      let bare = try XCTUnwrap(
        ZoneTextLayout.lines(parts.joined(), styles: styles(parts, padding: 0), width: 500).first)
      let padded = try XCTUnwrap(
        ZoneTextLayout.lines(parts.joined(), styles: styles(parts, padding: 4), width: 500).first)
      XCTAssertEqual(glyphCount(padded), glyphCount(bare), "\(name): 字を割らない")
      XCTAssertEqual(padded.width, bare.width + 8, accuracy: 0.01, "\(name): 幅は余白の分だけ増える")
      let (a, b) = (
        try XCTUnwrap(glyphs(of: 1, in: bare)), try XCTUnwrap(glyphs(of: 1, in: padded))
      )
      XCTAssertEqual(
        b.upperBound - b.lowerBound, a.upperBound - a.lowerBound, accuracy: 0.01,
        "\(name): コードの字の幅は変わらない")
      XCTAssertEqual(misplaced(padded, code: 1), [], name)
    }
  }

  /// 段落の向き 2 × コードの向き 2 × 隣の字の向き 2 の 8 通りを、行頭・行中・行末・折り返しをまたぐ置き方で組み、どの行でも
  /// コードの地が 1 つの続いた範囲で、余白が渡した幅で入り、隣の字が地にかぶらない。
  func testCodePaddingHoldsForEveryDirectionAndPosition() {
    let paragraphs = ["see the text ", "הנה הטקסט "]
    let codes = ["merges(event) ok", "מיזוג אירועים"]
    let neighbours = ["and more words", "ועוד מילים"]
    var wrong: [String] = []
    for paragraph in paragraphs {
      for code in codes {
        for neighbour in neighbours {
          let placements = [
            [code, " " + neighbour], [paragraph, code, " " + neighbour], [paragraph, code],
            [paragraph + neighbour + " ", code, " " + neighbour + " " + paragraph],
          ]
          for parts in placements {
            let index = parts.firstIndex(of: code)!
            for width in stride(from: CGFloat(60), through: 260, by: 3) {
              wrong += check(parts, code: index, width: width)
            }
          }
        }
      }
    }
    XCTAssertEqual(wrong, [])
  }

  /// 和文の隣、和文＋空白の隣、コードの端のタイ語 ำ・ラオ語 ຳ、左右の字が混ざったコード、字を挟まず隣り合うコード、
  /// 複数のコードにまたがる括弧でも、どの行でも同じ約束が守られる。
  func testCodePaddingHoldsNextToCJKAndAcrossMixedCodes() {
    let cases: [([String], [Int])] = [
      (["これは", "code", "です"], [1]), (["これは ", "code", " です"], [1]), (["見て", "กำ", "ที่นี่"], [1]),
      (["ເບິ່ງ ", "ກຳ", " ນີ້"], [1]), (["mix ", "abc שלום def", " end"], [1]),
      (["שלום ", "abc שלום def", " עולם"], [1]), (["a ", "first", "second", " b"], [1, 2]),
      (["(", "a(", "b)", ")"], [1, 2]), (["和文", "שלום", "和文"], [1]),
    ]
    var wrong: [String] = []
    for (parts, codes) in cases {
      for width in stride(from: CGFloat(30), through: 200, by: 1.5) {
        for code in codes { wrong += check(parts, code: code, width: width, codes: codes) }
      }
    }
    XCTAssertEqual(wrong, [])
  }

  /// 右から左の字・和文・括弧・コードを乱択で混ぜた段落 5,000 本で、コードの地が 1 行の中で割れず、コードの字を含み、
  /// ほかの字にかぶらない（余白の幅は問わない——右から左の向きで鏡像になる鉤括弧には、Core Text がコードの中で空きを置く）。
  func testRandomMixedParagraphsNeverSplitTheCodeGround() {
    var random = SplitMix(seed: 7)
    let words = [
      "あいう", "漢字", "abc", "de f", "אבג", "דה ו", " ", "、", "(", ")", "12", "กำ", "。", "x-y", "「",
      "」", ": ",
    ]
    var wrong: [String] = []
    for _ in 0..<5_000 {
      var parts: [String] = []
      var codes: [Int] = []
      for _ in 0..<(3 + random.next(9)) {
        if random.next(3) == 0 {
          codes.append(parts.count)
          parts.append(words[random.next(words.count)] + words[random.next(words.count)])
        } else {
          parts.append(words[random.next(words.count)])
        }
      }
      guard !codes.isEmpty else { continue }
      let width = CGFloat(60 + random.next(140))
      for code in codes {
        wrong += check(parts, code: code, width: width, codes: codes, measuresPadding: false)
      }
    }
    XCTAssertEqual(wrong.prefix(10), [])
  }

  /// 折り返しの位置は、余白を付けないときと同じ所から選ばれる——和文の直後のコードで、直前の字がコードと一緒に次の行へ
  /// 送られず、「」。の禁則も変わらない（コードと余白が 1 行に収まる幅で確かめる）。
  func testBreaksAreChosenFromTheSamePlacesAsWithoutPadding() {
    let cases: [([String], [Int])] = [
      (["あいうえお", "code", "かきくけこ"], [1]), (["これは", "a", "と", "b", "と", "c", "です。"], [1, 3, 5]),
      (["あいうえお「", "code", "」。かきく"], [1]), (["see the ", "code", " and then more words"], [1]),
    ]
    for (parts, codes) in cases {
      let string = parts.joined()
      var allowed = Set<Int>()
      for width in stride(from: CGFloat(10), through: 300, by: 0.5) {
        for line in ZoneTextLayout.lines(
          string, styles: styles(parts, codes: codes, padding: 0), width: width)
        {
          allowed.insert(line.range.location)
        }
      }
      let widest = codes.map {
        ZoneTextLayout.width([ZoneTextRun(parts[$0], font: mono, color: .red)]) + 2 * padding
      }.max()!
      for width in stride(from: widest + 12, through: 300, by: 0.5) {
        let starts = ZoneTextLayout.lines(
          string, styles: styles(parts, codes: codes, padding: padding), width: width
        ).map(\.range.location)
        XCTAssertTrue(
          starts.allSatisfy(allowed.contains), "\(string) を幅 \(width) で割った行の始まり \(starts)")
      }
    }
  }

  /// 和文と、右から左の字のインラインコードが同じ行にあっても、折り返したどの行も幅に収まる。
  func testWrappedLinesFitTheWidthWithPaddedCodeNextToCJKAndRightToLeftText() {
    for parts in [
      ["see the ", "קוד ארוך", " and more words here"],
      ["הריצו את ", "git commit -m", " ואז את זה"],
      ["これは", "קוד ארוך", "の例です。続きの文もある"], ["和文の後に ", "שלום עולם", " と続く和文の段落"],
    ] {
      let string = parts.joined()
      let over = stride(from: CGFloat(40), through: 200, by: 0.5).filter { width in
        ZoneTextLayout.lines(string, styles: styles(parts, padding: padding), width: width)
          .contains { $0.width > width + 0.001 }
      }
      XCTAssertEqual(over, [], "\(string) を折り返すと幅を超える行が出る幅")
    }
  }

  /// 元の文に置き字や双方向の制御字が入っていても、余白は包みの置き字にだけ付き、行の範囲は元の文を隙間なく割り、描く
  /// グリフにも包みの字は入らない。コードの中の閉じない制御字や対にならない終わり、コードの外の閉じない始まりがあっても、
  /// コードを包む向きの独立が壊れず、コードの後ろの字の並びが変わらない。
  func testControlCharactersInTheTextNeitherLeakNorBreakTheIsolate() throws {
    let cases: [(String, [String])] = [
      ("元の文の置き字と U+2060", ["a\u{FFFC}b ", "x\u{2060}y", " \u{FFFC} tail words"]),
      ("コードの中の閉じない上書き", ["abc ", "x\u{202E}y", " def ghi"]),
      ("コードの中の閉じない isolate", ["abc ", "x\u{2067}y", " def ghi"]),
      ("コードの中の対にならない終わり", ["abc ", "x\u{2069}y\u{202C}", " def ghi"]),
      ("右から左の段落の、コードの中の対にならない終わり", ["שלום ", "ab\u{2069}cd", " עולם"]),
      ("コードの外の閉じない始まり", ["a \u{2067}b ", "code", " c d"]),
      ("コードの外の向きの印", ["\u{200F}abc ", "co\u{200E}de", " \u{202A}def ghi"]),
    ]
    for (name, parts) in cases {
      let string = parts.joined()
      let lines = ZoneTextLayout.lines(string, styles: styles(parts, padding: padding), width: 500)
      XCTAssertEqual(lines.map(\.range), [NSRange(location: 0, length: string.utf16.count)], name)
      let line = try XCTUnwrap(lines.first)
      XCTAssertEqual(misplaced(line, code: 1), [], name)
      let bare = try XCTUnwrap(
        ZoneTextLayout.lines(string, styles: styles(parts, padding: 0), width: 500).first)
      XCTAssertEqual(glyphCount(line), glyphCount(bare), "\(name): 包みの字は描かない")
      if parts[2].hasSuffix("def ghi") {
        let tail = line.runs.filter { $0.style == 2 }.flatMap(\.positions).map(\.x)
        XCTAssertEqual(tail, tail.sorted(), "\(name): コードの後ろの字は左から右に並ぶ")
      }
    }
  }

  /// 当たり: 余白の左半分はコードの前の字の後、右半分はコードの字の前に当たり、どちらも元の文のコードの始まり。余白の上の
  /// 当たりとコードの端のキャレットは、置き字の外側の x に戻る。
  func testHitsOnThePaddingLandOnTheCodeEdges() throws {
    let parts = ["see ", "code", " here"]
    let line = try XCTUnwrap(
      ZoneTextLayout.lines(parts.joined(), styles: styles(parts, padding: padding), width: 500)
        .first)
    let ground = try XCTUnwrap(line.spans(of: 1).first)
    let code = try XCTUnwrap(glyphs(of: 1, in: line))
    XCTAssertEqual(line.offset(atX: ground.lowerBound + 1), 4, "前の余白の左半分")
    XCTAssertEqual(line.offset(atX: ground.lowerBound + 3), 4, "前の余白の右半分")
    XCTAssertEqual(line.offset(atX: code.upperBound + 1), 8, "後ろの余白の左半分")
    XCTAssertEqual(line.offset(atX: code.upperBound + 3), 8, "後ろの余白の右半分")
    XCTAssertEqual(line.x(of: 4), ground.lowerBound, accuracy: 0.01, "コードの始まりは余白の外")
    XCTAssertEqual(line.x(of: 8), ground.upperBound, accuracy: 0.01, "コードの終わりは余白の外")
    XCTAssertEqual(line.offset(atX: line.x(of: 6)), 6, "コードの中は字の境に戻る")
  }

  /// 段落の途中の行も段落の向きで組む——左から右の段落で右から左の字から始まる行でも、後ろの字はその右に、右から左の
  /// 段落で左から右の字から始まる行でも、後ろの字はその左に並ぶ。測った行と、その行を描く組版（まとまりの文とその行の範囲を
  /// 渡したもの）は同じ。
  func testAWrappedLineIsLaidOutInTheParagraphsDirection() throws {
    for (parts, width, rightToLeft) in [
      (["see ", "שלום עולם ארוך מאוד", " z"], CGFloat(90), false),
      (["שלום ", "aaaa bbbb cccc dddd", " עולם"], 90, true),
    ] {
      let string = parts.joined()
      let styles = styles(parts, padding: padding)
      let lines = ZoneTextLayout.lines(string, styles: styles, width: width)
      let index = try XCTUnwrap(
        lines.lastIndex {
          $0.range.location > parts[0].utf16.count && !$0.spans(of: 1).isEmpty
            && !$0.spans(of: 2).isEmpty
        }, "前提: \(string) に、コードの続きから始まって後ろの字が並ぶ行がある")
      let line = lines[index]
      let (code, after) = (line.spans(of: 1)[0], line.spans(of: 2)[0])
      if rightToLeft {
        XCTAssertLessThanOrEqual(after.upperBound, code.lowerBound + 0.01, "\(string): 後ろの字は左")
      } else {
        XCTAssertGreaterThanOrEqual(after.lowerBound, code.upperBound - 0.01, "\(string): 後ろの字は右")
      }
      let drawn = ZoneTextLayout.lines(
        of: ZoneText(
          id: 0, string: string, styles: styles,
          lines: lines.map { ZoneSelectableLine(origin: .zero, range: $0.range) }))
      XCTAssertEqual(drawn.map(\.range), lines.map(\.range), string)
      XCTAssertEqual(drawn[index].width, line.width, accuracy: 0.001, string)
      XCTAssertEqual(drawn[index].spans(of: 1), line.spans(of: 1), string)
    }
  }

  /// 描く行（まとまりの行の範囲から切り出したもの）は、測った行と幅も地も同じ——余白のあるコードが折り返しをまたぐ段落でも。
  func testDrawnLinesMatchTheMeasuredLines() {
    let parts = ["和文の段落に ", "merges(event) と長いコード", "が入り、", "שלום", " で終わる。"]
    let string = parts.joined()
    let styles = styles(parts, codes: [1, 3], padding: padding)
    for width in stride(from: CGFloat(50), through: 200, by: 7) {
      let measured = ZoneTextLayout.lines(string, styles: styles, width: width)
      let drawn = ZoneTextLayout.lines(
        of: ZoneText(
          id: 0, string: string, styles: styles,
          lines: measured.map { ZoneSelectableLine(origin: .zero, range: $0.range) }))
      for (a, b) in zip(measured, drawn) {
        XCTAssertEqual(a.range, b.range)
        XCTAssertEqual(a.width, b.width, accuracy: 0.001, "幅 \(width) の行 \(a.range)")
        XCTAssertEqual(a.spans(of: 1), b.spans(of: 1), "幅 \(width) の行 \(a.range)")
      }
    }
  }

  /// 組んだ字の連なりは見え方の境で分かれる（同じ字体でも）。
  func testRunsSplitAtEveryStyle() {
    let line = ZoneTextLayout.line([
      ZoneTextRun("red", font: font, color: .red), ZoneTextRun("green", font: font, color: .green),
    ])
    XCTAssertEqual(line.runs.map(\.style), [0, 1])
  }
}
