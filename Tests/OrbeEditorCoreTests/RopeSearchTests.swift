import Foundation
import XCTest

@testable import OrbeEditorCore

/// 検索と出現は本文の写しを窓ごとに読む。窓の境をまたぐ一致も、全文を 1 つの文字列にして探したときと同じ一致を同じ順に
/// 返す。裏の仕事は依頼の後に本文の写しを覚えない。壊れると、大きな文書で窓の境の一致が抜けたり二重になったり、
/// 裏が文書ごとに全文の写しを何本も抱える。
@MainActor
final class RopeSearchTests: XCTestCase {
  /// 全文を 1 つの NSString にして探す素朴な答え（大小無視・リテラル・重ならない）。
  private func reference(_ needle: String, _ text: String) -> [NSRange] {
    let string = text as NSString
    var result: [NSRange] = []
    var cursor = 0
    while cursor < string.length {
      let found = string.range(
        of: needle, options: [.caseInsensitive, .literal],
        range: NSRange(location: cursor, length: string.length - cursor))
      guard found.location != NSNotFound else { break }
      result.append(found)
      cursor = max(NSMaxRange(found), found.location + 1)
    }
    return result
  }

  func testWindowedSearchMatchesAWholeTextSearch() {
    var generator = SeededGenerator(seed: 31)
    let pieces = ["a", "A", "b", " ", "\n", "ab", "AB", "😀", "ß", "SS", "ﬃ", "ffi", "x.y", "é"]
    for round in 0..<60 {
      var text = ""
      for _ in 0..<Int.random(in: 20...400, using: &generator) {
        text += pieces.randomElement(using: &generator)!
      }
      let rope = TextRope(text)
      for needle in ["a", "ab", "ss", "ffi", "😀", "x.y", "b a"] {
        for window in [3, 7, 64] {
          XCTAssertEqual(
            TextSearch.matches(of: needle, in: rope, window: window), reference(needle, text),
            "\(round) 回目 needle \(needle) window \(window)")
        }
      }
    }
  }

  func testWindowedWordOccurrencesMatchAWholeTextSearch() {
    var generator = SeededGenerator(seed: 37)
    let pieces = ["foo", "bar", " ", ".", "_", "foo_bar", "\n", "(foo)", "xfoo", "😀"]
    for round in 0..<60 {
      var text = ""
      for _ in 0..<Int.random(in: 10...200, using: &generator) {
        text += pieces.randomElement(using: &generator)!
      }
      let rope = TextRope(text)
      guard let word = (text as NSString).range(of: "foo").nilIfNotFound else { continue }
      let whole = Occurrences.wordOccurrences(of: word, in: rope, window: 1 << 20)
      for window in [2, 5, 13] {
        XCTAssertEqual(
          Occurrences.wordOccurrences(of: word, in: rope, window: window), whole,
          "\(round) 回目 window \(window)")
      }
    }
  }

  /// 行差分・検索・出現の依頼を片付けた後、裏の仕事は本文の写しを持ち続けない。
  func testTheAnalysisKeepsNoCopyOfTheTextAfterTheWork() {
    let inbox = AnalysisInbox()
    let analysis = DocumentAnalysis(inbox: inbox)
    let text = TextRope(String(repeating: "let value = compute(offset)\n", count: 2_000))
    analysis.postHunks(text: text, version: 1, baseline: "", generation: 1)
    analysis.post(.find("value"), text: text, version: 1)
    analysis.post(.wordOccurrences(NSRange(location: 4, length: 5)), text: text, version: 1)
    var received = (hunks: false, ranges: 0)
    let deadline = DispatchTime.now() + 5
    while !(received.hunks && received.ranges == 2), inbox.wait(until: deadline) {
      let contents = inbox.take()
      received.hunks = received.hunks || contents.hunks != nil
      received.ranges += contents.ranges.count
    }
    XCTAssertTrue(received.hunks && received.ranges == 2, "前提: 3 つの結果が届く")
    let kept = Mirror(reflecting: analysis).children.filter { child in
      let type = String(describing: Swift.type(of: child.value))
      return ["String", "ContiguousArray<UInt16>", "TextRope"].contains { type.contains($0) }
    }
    XCTAssertEqual(kept.map { $0.label ?? "?" }, [], "本文の写しを覚えない")
  }
}

extension NSRange {
  fileprivate var nilIfNotFound: NSRange? { location == NSNotFound ? nil : self }
}
