import Foundation
import XCTest

@testable import OrbeEditorCore

/// 構文解析器——閉じた文書の解析は、走っている途中でも打ち切られる。
///
/// 壊れると何が起きるか。1MB の文書を開いてすぐ閉じても、裏がその全体の解析（debug で数秒）を最後まで走らせる。
final class SyntaxParserTests: XCTestCase {
  /// 解析の途中で閉じた印が立つと、解析は最後まで走らずに打ち切られる。印は、解析を呼ぶ直前に送る合図を受けて、別の
  /// スレッドで立てる——合図から印が立つまで（µs の桁）は、1MB の全体の解析（debug で秒の桁）より十分短い。印が解析の
  /// 入口の確かめより前に立った回は、途中を通らずに打ち切られる。そのため同じ場面を 5 回繰り返し、どの回も打ち切られる
  /// ことを確かめる。
  func testClosingStopsAParseInProgress() throws {
    let registry = LanguageRegistry(queriesRoot: Queries.root)
    let rules = try XCTUnwrap(registry.rules(for: SyntaxLanguage.swift))
    let text = TextRope(String(repeating: "let a = f(b, c) + 1 // note\n", count: 40_000))
    for round in 1...5 {
      let cancellation = SyntaxCancellation()
      let parser = SyntaxParser(cancellation: cancellation)
      let signal = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        signal.wait()
        cancellation.cancel()
      }
      let started = Date()
      signal.signal()
      let outcome = parser.parse(rules.language, ranges: [], old: nil, text: text, origin: 0)
      guard case .cancelled = outcome else {
        return XCTFail("\(round) 回目: \(Date().timeIntervalSince(started)) 秒で最後まで解析した")
      }
    }
  }
}
