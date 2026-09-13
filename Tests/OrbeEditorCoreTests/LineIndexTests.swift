import Foundation
import XCTest

@testable import OrbeEditorCore

/// 行頭索引——オフセット⇄(行, 桁) と、編集後の索引が本文から作り直したものと一致すること。
/// 壊れると tree-sitter へ渡す InputEdit の点がずれ、編集のたびに構文木が壊れて色が乱れる。
final class LineIndexTests: XCTestCase {
  func testPointsAndLineRanges() {
    let index = LineIndex(text: "ab\ncd\n\nefg")
    XCTAssertEqual(index.lineCount, 4)
    XCTAssertEqual(index.point(at: 0).row, 0)
    XCTAssertEqual(index.point(at: 2).column, 2, "改行の位置はその行の末尾")
    XCTAssertEqual(index.point(at: 3).row, 1)
    XCTAssertEqual(index.point(at: 6).row, 2)
    XCTAssertEqual(index.point(at: 9).row, 3)
    XCTAssertEqual(index.point(at: 9).column, 2)
    XCTAssertEqual(index.lineRange(0, textLength: 10), NSRange(location: 0, length: 3))
    XCTAssertEqual(index.lineRange(2, textLength: 10), NSRange(location: 6, length: 1))
    XCTAssertEqual(index.lineRange(3, textLength: 10), NSRange(location: 7, length: 3))
  }

  func testEmptyAndTrailingNewline() {
    XCTAssertEqual(LineIndex(text: "").lineCount, 1)
    let index = LineIndex(text: "a\n")
    XCTAssertEqual(index.lineCount, 2, "末尾の改行の後に空の最終行がある")
    XCTAssertEqual(index.point(at: 2).row, 1)
  }

  /// UTF-16 単位で数える（サロゲートペアは 2）。
  func testCountsUTF16Units() {
    let index = LineIndex(text: "😀\nx")
    XCTAssertEqual(index.point(at: 3).row, 1)
    XCTAssertEqual(index.point(at: 2).column, 2)
  }

  /// 挿入・削除・複数行の置換・改行を跨ぐ削除のどれでも、更新した索引は作り直した索引と等しい。
  func testApplyMatchesRebuild() {
    let base = "one\ntwo\nthree\nfour"
    let edits: [(NSRange, String)] = [
      (NSRange(location: 4, length: 0), "x"),
      (NSRange(location: 4, length: 3), ""),
      (NSRange(location: 2, length: 5), "A\nB\nC"),
      (NSRange(location: 3, length: 1), ""),
      (NSRange(location: 0, length: 18), ""),
      (NSRange(location: 18, length: 0), "\n\n"),
      (NSRange(location: 7, length: 1), "\r\n"),
    ]
    for (range, replacement) in edits {
      var index = LineIndex(text: base)
      let text = NSMutableString(string: base)
      text.replaceCharacters(in: range, with: replacement)
      index.apply(
        TextEdit(range: range, replacementLength: (replacement as NSString).length),
        replacement: replacement)
      XCTAssertEqual(
        index, LineIndex(text: text as String), "\(range) → \(replacement.debugDescription)")
    }
  }
}
