import Foundation
import XCTest

@testable import OrbeEditorCore

/// 構文解析器——閉じた文書の解析は、走っている途中でも打ち切られる。
///
/// 壊れると何が起きるか。1MB の文書を開いてすぐ閉じても、裏がその全体の解析（debug で数秒）を最後まで走らせる。
final class SyntaxParserTests: XCTestCase {
  /// 解析の途中で閉じた印が立つと、解析は最後まで走らずに打ち切られる。印は解析を始めてから 20ms 後に別のスレッドで立てる
  /// ——1MB の全体の解析はそれより十分長い。
  func testClosingStopsAParseInProgress() throws {
    let registry = LanguageRegistry(queriesRoot: Queries.root)
    let rules = try XCTUnwrap(registry.rules(for: SyntaxLanguage.swift))
    let text = TextRope(String(repeating: "let a = f(b, c) + 1 // note\n", count: 40_000))
    let cancellation = SyntaxCancellation()
    let parser = SyntaxParser(cancellation: cancellation)
    let started = Date()
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
      cancellation.cancel()
    }
    let outcome = parser.parse(rules.language, ranges: [], old: nil, text: text, origin: 0)
    guard case .cancelled = outcome else {
      return XCTFail("\(Date().timeIntervalSince(started)) 秒で最後まで解析した")
    }
  }
}
