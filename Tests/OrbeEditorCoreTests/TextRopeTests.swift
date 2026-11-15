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
    let offsets = stride(from: 0, through: text.length, by: max(1, text.length / 97))
    for offset in Array(offsets) + [text.length] {
      let row = starts.lastIndex { $0 <= offset }!
      XCTAssertEqual(rope.row(containing: offset), row, "オフセット \(offset)", file: file, line: line)
      XCTAssertEqual(rope.point(at: offset).column, offset - starts[row], file: file, line: line)
    }
    XCTAssertEqual(Array(rope.utf16), Array((text as String).utf16), file: file, line: line)
    let ranges = stride(from: 0, to: text.length, by: max(4, text.length / 211)).enumerated().map {
      NSRange(location: $0.element, length: min($0.offset % 4, text.length - $0.element))
    }
    XCTAssertEqual(
      rope.rows(ofAscending: ranges), ranges.map(rope.rows(of:)), "昇順の区間の行", file: file, line: line)
    let count = starts.count
    for rows in [0..<count, (count / 3)..<(count / 2 + 1), (count - 1)..<(count + 2)] {
      XCTAssertEqual(
        rope.lineStarts(rows), (rows.lowerBound...rows.upperBound).map(rope.lineStart),
        "行 \(rows) の行頭", file: file, line: line)
      for limit in [0, 3, 2000] {
        let heads = rope.lineHeads(rows, limit: limit)
        for (index, row) in rows.enumerated() {
          let start = rope.lineStart(row)
          let length = rope.lineEnd(row) - start
          XCTAssertEqual(
            Array(heads.head(index)),
            Array(rope.units(in: NSRange(location: start, length: min(length, limit)))),
            "行 \(row) の頭 \(limit) 単位", file: file, line: line)
          XCTAssertEqual(heads.isComplete(index), length <= limit, file: file, line: line)
        }
      }
    }
    var offset = 0
    for chunk in chunks(of: rope) {
      offset += chunk.count
      if UTF16.isLeadSurrogate(chunk.last!), offset < text.length {
        XCTAssertFalse(
          UTF16.isTrailSurrogate(text.character(at: offset)), "塊の境 \(offset) でサロゲートの対を割った",
          file: file, line: line)
      }
    }
    XCTAssertEqual(offset, text.length, "塊を辿ると本文の終わりに着く", file: file, line: line)
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

  /// 置換の中身は UTF-16 の単位のまま入る——サロゲートの対の片割れも化けずに残り、戻せば元の対になる。編集の絞り込みも
  /// 片割れを単位のまま運ぶ。
  func testReplacingWithUnitsKeepsALoneSurrogate() {
    var rope = TextRope("a😀b")
    let lead = ContiguousArray<UInt16>([0xD83D])
    rope.replace(NSRange(location: 1, length: 1), with: ContiguousArray("x".utf16))
    XCTAssertEqual(Array(rope.contiguousUnits()), [0x61, 0x78, 0xDE00, 0x62])
    let undo = TextEdit(range: NSRange(location: 1, length: 1), replacement: lead)
    rope.replace(undo.range, with: undo.replacement)
    XCTAssertEqual(Array(rope.contiguousUnits()), Array("a😀b".utf16), "元の対に戻る")
    XCTAssertEqual(rope.utf8Data(), Data("a😀b".utf8))
    let whole = TextEdit(
      range: NSRange(location: 0, length: 3), replacement: ContiguousArray([0x61, 0xD83D, 0x63]))
    XCTAssertEqual(
      whole.narrowed(replacing: ContiguousArray([0x61, 0x78, 0x63])).replacement, lead,
      "片割れを単位のまま運ぶ")
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

  /// 中身が同じかは塊の切れ目に依らない——打って消した後は、中身が同じでも塊の切れ目が元と違う。違いが末尾 1 字でも、
  /// 長さだけが違っても見分ける。
  func testSameContentIgnoresChunkBoundaries() {
    let text = String(repeating: "abcdefg\n", count: 3000)
    let original = TextRope(text)
    var edited = original
    edited.replace(NSRange(location: 700, length: 0), with: String(repeating: "x", count: 300))
    edited.replace(NSRange(location: 700, length: 300), with: "")
    edited.replace(NSRange(location: 5000, length: 1), with: "")
    edited.replace(NSRange(location: 5000, length: 0), with: "a")
    XCTAssertEqual(edited.substring(NSRange(location: 0, length: edited.length)), text, "前提: 中身は同じ")
    XCTAssertNotEqual(
      chunks(of: edited).map(\.count), chunks(of: original).map(\.count), "前提: 切れ目が違う")
    XCTAssertTrue(edited.hasSameContent(as: original))
    XCTAssertTrue(TextRope().hasSameContent(as: TextRope("")))

    var last = original
    last.replace(NSRange(location: last.length - 1, length: 1), with: "!")
    XCTAssertFalse(last.hasSameContent(as: original))
    XCTAssertFalse(TextRope(text + "x").hasSameContent(as: original))
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

  /// tree-sitter の読み口は、オフセットからその塊の終わりまでをバッファへ写し、続けて読めば本文全体になる。サロゲートの
  /// 対は塊の境で割れない。
  func testChunkReadsCoverTheTextAndKeepSurrogatePairsTogether() {
    let text = String(repeating: "x😀", count: 3000)
    let rope = TextRope(text)
    var units: [UInt16] = []
    for chunk in chunks(of: rope) {
      XCTAssertFalse(chunk.isEmpty)
      XCTAssertFalse(UTF16.isLeadSurrogate(chunk.last!), "塊の終わりで対を割らない")
      units += chunk
    }
    XCTAssertEqual(String(decoding: units, as: UTF16.self), text)
    XCTAssertEqual(rope.utf8Data(), Data(text.utf8))
  }

  /// 読み口で先頭から塊を順に読む。
  private func chunks(of rope: TextRope) -> [[UInt16]] {
    let buffer = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: TextRope.chunkCapacity)
    defer { buffer.deallocate() }
    var result: [[UInt16]] = []
    var offset = 0
    while case let count = rope.copyChunk(at: offset, into: buffer), count > 0 {
      result.append(Array(buffer[..<count]))
      offset += count
    }
    return result
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
