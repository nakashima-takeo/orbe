import Foundation
import XCTest

@testable import OrbeEditorCore

/// 誤りを含む構文木の色の枠——字の色はその字の区画の枠で決まり、誤りを含まない木には枠を掛けない。
///
/// 壊れると何が起きるか。崩れた大きな文書で、同じ字の色が作り直しの履歴で変わる。誤りの無い大きな文書（区画をいくつも
/// またぐコメントや文字列を持つ JSON など）で色が落ちる。どちらも色の乱択を素通りする。
final class SyntaxCrumbledFrameTests: XCTestCase {
  private let registry = LanguageRegistry(queriesRoot: Queries.root)

  /// 誤りを含む木では、字の色はその字の区画の枠で決まり、区間の切り方に依らない。約 80K 字の Swift（閉じない `f(` と、
  /// 区画をいくつもまたぐコメント）で、区画の格子と揃わない区間の答えを、全体の答えをその区間で切ったものと比べる。
  func testCrumbledRolesDoNotDependOnWhereTheRangeIsCut() throws {
    var source = String(repeating: "let a = b + 1 // c\n", count: 500)
    source += "let v = f(\n"
    source += String(repeating: "let a = b + 1 // c\n", count: 950)
    source += "/*\n" + String(repeating: "note\n", count: 5_800) + "*/\n"
    source += String(repeating: "let a = b + 1 // c\n", count: 1_200)
    let layers = try parsed(source, .swift)
    let text = TextRope(source)
    XCTAssertEqual(layers.allLayers.first?.layer.tree?.hasError, true, "前提: 誤りを含む")
    let whole = layers.roles(in: NSRange(location: 0, length: text.length))
    var mismatches: [Int] = []
    for start in stride(from: 0, to: text.length, by: 1009) {
      let range = NSRange(location: start, length: min(5000, text.length - start))
      let expected = whole.compactMap { span -> HighlightSpan? in
        let clipped = NSIntersectionRange(span.range, range)
        return clipped.length > 0 ? HighlightSpan(range: clipped, role: span.role) : nil
      }
      if layers.roles(in: range) != expected { mismatches.append(start) }
    }
    XCTAssertEqual(mismatches, [], "区間の切り方で答えが変わった")
  }

  /// 誤りを含まない木には枠を掛けない——余白を超える大きな構文（区画をいくつもまたぐコメント）の真ん中にも色が付く。
  func testAHealthyTreeColorsAConstructLargerThanTheMargin() throws {
    let comment = "/*\n" + String(repeating: "note\n", count: 20_000) + "*/\n"
    let source = "let a = 1\n" + comment + "let b = 2\n"
    let layers = try parsed(source, .swift)
    XCTAssertEqual(layers.allLayers.first?.layer.tree?.hasError, false, "前提: 誤りを含まない")
    let middle = source.utf16.count / 2
    XCTAssertGreaterThan(middle - 10, SyntaxLayers.block + SyntaxLayers.margin, "前提: 余白を超える")
    XCTAssertEqual(
      layers.roles(in: NSRange(location: middle, length: 4)).map(\.role), [.comment])
  }

  private func parsed(_ source: String, _ language: SyntaxLanguage) throws -> SyntaxLayers {
    let layers = SyntaxLayers(
      rules: try XCTUnwrap(registry.rules(for: language)), registry: registry,
      cancellation: SyntaxCancellation())
    layers.parseAll(TextRope(source))
    return layers
  }
}
