import XCTest

@testable import Orbe

/// emoji-presentation 全域集合の実行時導出（`EmojiPresentationRanges`）の検証。
/// 判定源は chrome（TitleGlyphs）と同じ `isEmojiPresentation` なので、ここで固定する含有/非含有が
/// 端末セル（font-codepoint-map）とタブの出し分けの両方を規定する。
final class EmojiFontTests: XCTestCase {

  /// 既知の emoji-presentation 点を含む（😀 顔・✅ 記号・⌚ BMP・👍 手・肌色修飾子）。
  func testRangesContainKnownEmojiPresentationCodepoints() {
    XCTAssertTrue(EmojiPresentationRanges.contains(0x1F600), "😀")
    XCTAssertTrue(EmojiPresentationRanges.contains(0x2705), "✅")
    XCTAssertTrue(EmojiPresentationRanges.contains(0x231A), "⌚")
    XCTAssertTrue(EmojiPresentationRanges.contains(0x1F44D), "👍")
    XCTAssertTrue(EmojiPresentationRanges.contains(0x1F3FB), "肌色修飾子（Emoji_Presentation=Yes）")
  }

  /// text-presentation の記号（‼ ℹ ▪ 等・VS 無しでモノクロ）は含まない＝出し分けを壊さない。
  func testRangesExcludeTextPresentationSymbols() {
    XCTAssertFalse(EmojiPresentationRanges.contains(0x203C), "‼")
    XCTAssertFalse(EmojiPresentationRanges.contains(0x2139), "ℹ")
    XCTAssertFalse(EmojiPresentationRanges.contains(0x25AA), "▪")
    XCTAssertFalse(EmojiPresentationRanges.contains(0x25FB), "◻")
  }

  /// ZWJ・VS16 は default-ignorable（クラスタ shaping 側が処理）なので map に含めない。
  func testRangesExcludeJoinersAndVariationSelectors() {
    XCTAssertFalse(EmojiPresentationRanges.contains(0x200D), "ZWJ")
    XCTAssertFalse(EmojiPresentationRanges.contains(0xFE0F), "VS16")
  }

  /// conf 値は ghostty `font-codepoint-map` のキー構文（`U+XXXX`／`U+XXXX-U+YYYY` の comma 連結）。
  func testConfValueFormat() {
    let value = EmojiPresentationRanges.confValue
    XCTAssertTrue(value.hasPrefix("U+"), "先頭は U+")
    XCTAssertFalse(value.contains(" "), "空白を含まない")
    let pattern = #"^U\+[0-9A-F]{4,5}(-U\+[0-9A-F]{4,5})?$"#
    for part in value.split(separator: ",") {
      XCTAssertNotNil(
        String(part).range(of: pattern, options: .regularExpression), "不正な範囲表記: \(part)")
    }
  }

  /// 行全体（キー＋map 先）が ghostty config の行長上限（LineIterator.MAX_LINE_SIZE=4096B）に収まる。
  /// OS の Unicode 更新で集合が伸びても、ここが緑なら 1 行 emit が壊れていない。
  func testConfValueFitsGhosttyLineLimit() {
    let line = "font-codepoint-map = \(EmojiPresentationRanges.confValue)=Noto Color Emoji"
    XCTAssertLessThan(line.utf8.count, 4000)
  }

  /// 範囲は昇順・非隣接（圧縮済み）で、逆走査（後勝ち照会）に依存しない一意な集合になっている。
  func testRangesAreSortedAndCoalesced() {
    let ranges = EmojiPresentationRanges.ranges
    XCTAssertFalse(ranges.isEmpty)
    for (a, b) in zip(ranges, ranges.dropFirst()) {
      XCTAssertLessThan(a.upperBound + 1, b.lowerBound, "隣接/重複範囲は圧縮されている")
    }
  }
}
