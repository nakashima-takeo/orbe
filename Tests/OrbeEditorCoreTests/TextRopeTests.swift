import Foundation
import XCTest

@testable import OrbeEditorCore

/// 本文の写し（ロープ）と、その下の要約付き B 木。乱択の置換を NSString と同じに追い、行とオフセットの変換が行の定義
/// （`\n` だけで割る）どおりになる。壊れると色・印・検索が字からずれ、保存した内容が面の本文と違う。
final class TextRopeTests: XCTestCase {
  /// 行頭オフセットの素朴な答え（`\n` の直後）。
  private func lineStarts(_ text: NSString) -> [Int] {
    var starts = [0]
    for offset in 0..<text.length where text.character(at: offset) == 0x0A {
      starts.append(offset + 1)
    }
    return starts
  }

  private func assertMatches(
    _ rope: TextRope, _ text: NSString, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(rope.length, text.length, file: file, line: line)
    XCTAssertEqual(
      rope.substring(NSRange(location: 0, length: rope.length)), text as String, file: file,
      line: line)
    let starts = lineStarts(text)
    XCTAssertEqual(rope.lineCount, starts.count, file: file, line: line)
    for (row, start) in starts.enumerated() {
      XCTAssertEqual(rope.lineStart(row), start, "行 \(row) の行頭", file: file, line: line)
      XCTAssertEqual(
        rope.lineEnd(row), row + 1 < starts.count ? starts[row + 1] : text.length, file: file,
        line: line)
    }
    for offset in stride(from: 0, through: text.length, by: max(1, text.length / 97)) {
      let row = starts.lastIndex { $0 <= offset }!
      XCTAssertEqual(rope.row(containing: offset), row, "オフセット \(offset)", file: file, line: line)
      XCTAssertEqual(rope.point(at: offset).column, offset - starts[row], file: file, line: line)
    }
    XCTAssertEqual(Array(rope.utf16), Array((text as String).utf16), file: file, line: line)
  }

  /// 乱択の置換（挿入・削除・置換・大きな貼り付け・改行と CRLF とサロゲートを含む）を NSString と同じに追う。
  func testRandomEditsMatchAStringReference() {
    var generator = SeededGenerator(seed: 7)
    let pieces = [
      "a", "bc", "\n", "\r\n", "\r", "😀", "漢字", "  x\n  y", String(repeating: "q", count: 700),
    ]
    let reference = NSMutableString()
    var rope = TextRope()
    for step in 0..<600 {
      let location = Int.random(in: 0...reference.length, using: &generator)
      let length = Int.random(in: 0...min(40, reference.length - location), using: &generator)
      var replacement = ""
      for _ in 0..<Int.random(in: 0...3, using: &generator) {
        replacement += pieces.randomElement(using: &generator)!
      }
      if step % 97 == 0 {
        replacement = String(repeating: "line of text\n", count: 400)
      }
      let range = NSRange(location: location, length: length)
      reference.replaceCharacters(in: range, with: replacement)
      rope.replace(range, with: replacement)
      if step % 50 == 0 { assertMatches(rope, reference) }
    }
    assertMatches(rope, reference)
    rope.replace(NSRange(location: 0, length: rope.length), with: "")
    assertMatches(rope, "")
  }

  /// 写しは変わらない——写した後に元を置換しても、写しの本文は写したときのまま。
  func testCopiesAreUnaffectedByLaterEdits() {
    var rope = TextRope(String(repeating: "abc\n", count: 5000))
    let snapshot = rope
    rope.replace(NSRange(location: 10, length: 5), with: "XYZ")
    rope.replace(NSRange(location: 15_000, length: 0), with: String(repeating: "new\n", count: 900))
    XCTAssertEqual(snapshot.length, 20_000)
    XCTAssertEqual(
      snapshot.substring(NSRange(location: 0, length: snapshot.length)),
      String(repeating: "abc\n", count: 5000))
    XCTAssertEqual(snapshot.lineCount, 5001)
  }

  /// 行は `\n` だけで割る——CRLF の `\r` は行の中身、単独の `\r` と U+2028 は行を割らない。末尾の改行の後は空行が 1 つ。
  func testLinesSplitOnlyOnLineFeed() {
    let rope = TextRope("a\r\nb\rc\u{2028}d\n")
    XCTAssertEqual(rope.lineCount, 3)
    XCTAssertEqual(rope.lineStart(1), 3)
    XCTAssertEqual(rope.lineEnd(1), 9)
    XCTAssertEqual(rope.lineStart(2), 9)
    XCTAssertEqual(rope.lineEnd(2), 9)
    XCTAssertEqual(rope.rows(of: NSRange(location: 0, length: 4)), 0...1)
    XCTAssertEqual(rope.rows(of: NSRange(location: 3, length: 0)), 1...1)
  }

  /// tree-sitter の読み口は、オフセットからその塊の終わりまでを UTF-16LE で返し、続けて読めば本文全体になる。サロゲートの
  /// 対は塊の境で割れない。
  func testChunkReadsCoverTheTextAndKeepSurrogatePairsTogether() {
    let text = String(repeating: "x😀", count: 3000)
    let rope = TextRope(text)
    var data = Data()
    var offset = 0
    while let chunk = rope.chunkData(at: offset) {
      XCTAssertFalse(chunk.isEmpty)
      let units = chunk.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
      XCTAssertFalse(UTF16.isLeadSurrogate(units.last!), "塊の終わりで対を割らない")
      data.append(chunk)
      offset += chunk.count / 2
    }
    XCTAssertEqual(String(data: data, encoding: .utf16LittleEndian), text)
    XCTAssertEqual(rope.utf8Data(), Data(text.utf8))
  }
}

/// 再現できる乱数（テストの乱択を毎回同じにする）。
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}
