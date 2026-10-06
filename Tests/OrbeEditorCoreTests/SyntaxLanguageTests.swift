import Foundation
import OrbeTestSupport
import XCTest

@testable import OrbeEditorCore

/// 拡張子・ファイル名からの言語の決定と、16 文法すべての queries が `.build` の資源バンドルから解けること。
final class SyntaxLanguageTests: XCTestCase {
  func testDetectByExtensionAndName() {
    func lang(_ name: String) -> SyntaxLanguage? {
      SyntaxLanguage.detect(url: URL(fileURLWithPath: "/x/\(name)"))
    }
    XCTAssertEqual(lang("a.JSON"), .json, "拡張子は大文字小文字を区別しない")
    XCTAssertEqual(lang("Dockerfile"), .dockerfile)
    XCTAssertEqual(lang("Dockerfile.dev"), .dockerfile)
    XCTAssertNil(lang("LICENSE"))
    XCTAssertNil(lang("a.txt"))
  }

  /// 16 文法の queries（highlights・injections）が全部読めて Query に組める。
  func testEveryGrammarResolvesFromBuildProducts() {
    let registry = LanguageRegistry(queriesRoot: Queries.root)
    for grammar in Grammar.allCases {
      let rules = registry.rules(for: grammar)
      XCTAssertNotNil(rules, "\(grammar) の queries が解けない（\(Queries.root.path)）")
      if grammar.injectionFile != nil {
        XCTAssertNotNil(rules?.injections, "\(grammar) に injections が無い")
      }
    }
    XCTAssertNotNil(registry.rules(forInjection: "markdown_inline"))
    XCTAssertNotNil(registry.rules(forInjection: "ts"))
    XCTAssertNil(registry.rules(forInjection: "regex"), "持たない言語は nil（injection は無視される）")
  }

  func testMissingRootMeansNoColors() {
    XCTAssertNil(LanguageRegistry(queriesRoot: nil).rules(for: SyntaxLanguage.swift))
    let empty = TestScratch.caseDir.appendingPathComponent("orbe-no-queries")
    XCTAssertNil(LanguageRegistry(queriesRoot: empty).rules(for: SyntaxLanguage.swift))
  }
}
