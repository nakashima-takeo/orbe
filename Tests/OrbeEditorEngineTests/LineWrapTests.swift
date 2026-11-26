import CoreText
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 行の折り返しの規則——段を分ける位置と、段の幅が組んだ幅と食い違わないこと。壊れると、折り返した段の右端が切れる、
/// 句読点や小書きのかなが段の頭に来る、語の途中で段が分かれる。
final class LineWrapTests: XCTestCase {
  private let font = CTFontCreateUIFontForLanguage(.userFixedPitch, 12, nil)!

  private var cell: CGFloat {
    LineShaper.shape(" ", font: font).width
  }

  private func metrics(columns: Double, tab: Int = 4) -> LineWrap.Metrics {
    LineWrap.Metrics(
      font: font, width: CGFloat(columns) * cell, tabWidth: CGFloat(tab) * cell
    ) { _ in 0 }
  }

  /// 行 `line` の段の中身。
  private func segments(_ line: String, _ metrics: LineWrap.Metrics) -> [String] {
    let shown = LineShaper.display(LineShaper.source(line))
    guard let wrap = LineWrap.wrap(shown, metrics) else { return [line] }
    let units = Array(line.utf16)
    return (0..<wrap.segments).map { segment in
      let end = segment + 1 < wrap.segments ? wrap.start(of: segment + 1) : units.count
      return String(decoding: units[wrap.start(of: segment)..<end], as: UTF16.self)
    }
  }

  func testFittingLinesStayOnOneSegment() {
    XCTAssertNil(
      LineWrap.wrap(LineShaper.display(LineShaper.source("short")), metrics(columns: 10)))
    XCTAssertNil(
      LineWrap.wrap(LineShaper.display(LineShaper.source("あいうえお")), metrics(columns: 10)))
  }

  /// 空白の並びの後ろで分け、空白は段の終わりに残る（空白の前では分けない）。
  func testBreaksAfterSpaces() {
    XCTAssertEqual(segments("hello world again", metrics(columns: 12)), ["hello world ", "again"])
    XCTAssertEqual(segments("aaaa bbbb cccc", metrics(columns: 7)), ["aaaa ", "bbbb ", "cccc"])
  }

  /// 分けてよい位置が無ければ書記素の境で分ける。どの段にも書記素が 1 つは入る。
  func testLongWordsBreakAtGraphemes() {
    XCTAssertEqual(segments("abcdefghij", metrics(columns: 4)), ["abcd", "efgh", "ij"])
    XCTAssertEqual(segments("abc", metrics(columns: 0.5)), ["a", "b", "c"])
    XCTAssertEqual(segments("👍🏽👍🏽👍🏽", metrics(columns: 3)).joined(), "👍🏽👍🏽👍🏽")
  }

  /// 和文の字の前後で分け、句読点・閉じ括弧・小書きのかな・長音は段の頭に来ない。開き括弧は段の終わりに残らない。
  func testJapaneseKinsoku() {
    let narrow = metrics(columns: 6)
    for line in ["あいうえ。おかき", "あいうえっおかき", "あいうえーおかき", "あいう「えお」かき"] {
      for segment in segments(line, narrow).dropFirst() {
        XCTAssertFalse(
          "。、」）っーァ".contains(segment.first!), "\(line) の段 \(segment) の頭")
      }
      for segment in segments(line, narrow).dropLast() {
        XCTAssertFalse("「（".contains(segment.last!), "\(line) の段 \(segment) の終わり")
      }
      XCTAssertEqual(segments(line, narrow).joined(), line)
    }
  }

  /// 続きの段は行頭の空白の幅だけ字下げする。字下げが折り返しの幅の半分を超えれば字下げしない。
  func testContinuationIndent() {
    let shown = LineShaper.display(LineShaper.source("    aaa bbb ccc ddd"))
    let wrap = LineWrap.wrap(shown, metrics(columns: 12))
    XCTAssertEqual(wrap.map { CGFloat($0.indent) }, 4 * cell)
    let deep = LineWrap.wrap(
      LineShaper.display(LineShaper.source("        aaa bbb")), metrics(columns: 12))
    XCTAssertEqual(deep?.indent, 0)
  }

  /// 前の折り返しを引き継いで決め直した段は、行の頭から決めた段と同じ——語・和文・タブ・結合文字・絵文字・行頭の空白を
  /// 含む行の、どこを編集しても（打ち切った行の末尾で打っても）。
  func testResumingMatchesWrappingFromTheStart() {
    let pieces = [
      "word ", "語", "、", "（", "）", "\t", "e\u{301}", "😀", "👩‍💻", "  ", "x", "longidentifier", "。",
    ]
    var generator = SplitMix(seed: 11)
    for columns in [13.0, 40] {
      let metrics = metrics(columns: columns)
      for _ in 0..<400 {
        var line = (0..<Int.random(in: 1...60, using: &generator)).map { _ in
          pieces.randomElement(using: &generator)!
        }.joined()
        let units = Array(line.utf16)
        let at = Int.random(in: 0...units.count, using: &generator)
        let removed = Int.random(in: 0...min(3, units.count - at), using: &generator)
        let inserted = Array(pieces.randomElement(using: &generator)!.utf16)
        let shownBefore = LineShaper.display(LineShaper.source(line))
        line = String(decoding: units[..<at] + inserted + units[(at + removed)...], as: UTF16.self)
        guard let old = LineWrap.wrap(shownBefore, metrics) else { continue }
        let shown = LineShaper.display(LineShaper.source(line))
        XCTAssertEqual(
          LineWrap.wrap(shown, metrics, resuming: LineWrap.Resume(old: old, edited: at)),
          LineWrap.wrap(shown, metrics), "\(columns) 桁: \(line)")
      }
    }
    // 打ち切った行の末尾の印の幅は、打ち切った単位の数の桁で変わる（桁の数 + 1 桁）。
    let cell = cell
    for columns in [40.0, 41] {
      let marked = LineWrap.Metrics(
        font: font, width: CGFloat(columns) * cell, tabWidth: 4 * cell
      ) { CGFloat(String($0).count + 1) * cell }
      for (omitted, edit) in [(50, "abc"), (1_000, ""), (99, "xx")] {
        let long = String(repeating: "x", count: LineShaper.limit + omitted)
        let old = LineWrap.wrap(LineShaper.display(LineShaper.source(long)), marked)!
        // 打ち切った部分の 1 字を、`edit` に置き換える（印の桁が変わりうる）。
        let at = LineShaper.limit + omitted / 2
        var units = Array(long.utf16)
        units.replaceSubrange(at..<at + 1, with: Array(edit.utf16))
        let shown = LineShaper.display(LineShaper.source(String(decoding: units, as: UTF16.self)))
        XCTAssertEqual(
          LineWrap.wrap(shown, marked, resuming: LineWrap.Resume(old: old, edited: at)),
          LineWrap.wrap(shown, marked), "\(columns) 桁・打ち切った \(omitted) 単位の中を編集する")
      }
    }
  }

  /// 段を独立した行として組んだ幅（字下げを含む）は、折り返しの幅に収まる——本文の字・記号・タブ・書式文字の箱を含む行で。
  func testShapedSegmentsFitTheWidth() {
    let lines = [
      String(repeating: "日本語の文と English words が混ざる行。", count: 6),
      String(repeating: "※記号★と◐、全角の（括弧）と ① を含む。", count: 6),
      String(repeating: "\tタブ\tを\t含む\t行 ", count: 8),
      String(repeating: "longidentifier_", count: 20),
      String(repeating: "abc\u{202E}def\u{200E} ", count: 12),
    ]
    for columns in [17.0, 40, 63.5] {
      let metrics = metrics(columns: columns)
      for line in lines {
        let shown = LineShaper.display(LineShaper.source(line))
        guard let wrap = LineWrap.wrap(shown, metrics) else {
          XCTFail("\(columns) 桁で折り返す")
          continue
        }
        for segment in 0..<wrap.segments {
          let end = segment + 1 < wrap.segments ? wrap.start(of: segment + 1) : shown.units.count
          let start = wrap.start(of: segment)
          XCTAssertLessThan(start, end, "どの段にも字がある")
          let piece = shown.segment(start..<end, last: segment + 1 == wrap.segments)
          let width =
            LineShaper.shape(piece, font: font, tabWidth: metrics.tabWidth).width
            + (segment > 0 ? CGFloat(wrap.indent) : 0)
          XCTAssertLessThanOrEqual(width, metrics.width + 0.01, "\(columns) 桁の段 \(segment)")
        }
      }
    }
  }
}
