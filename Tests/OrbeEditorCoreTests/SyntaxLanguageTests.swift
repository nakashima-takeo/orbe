import Foundation
import XCTest

@testable import OrbeEditorCore

/// 拡張子・ファイル名からの言語の決定と、16 文法すべての queries が `.build` の資源バンドルから解けること。
final class SyntaxLanguageTests: XCTestCase {
  func testDetectByExtensionAndName() {
    func lang(_ name: String) -> SyntaxLanguage? {
      SyntaxLanguage.detect(url: URL(fileURLWithPath: "/x/\(name)"))
    }
    XCTAssertEqual(lang("a.swift"), .swift)
    XCTAssertEqual(lang("README.md"), .markdown)
    XCTAssertEqual(lang("a.JSON"), .json, "拡張子は大文字小文字を区別しない")
    XCTAssertEqual(lang("a.ts"), .typescript)
    XCTAssertEqual(lang("a.mjs"), .javascript)
    XCTAssertEqual(lang("a.jsx"), .javascript)
    XCTAssertEqual(lang("a.tsx"), .tsx)
    XCTAssertEqual(lang("a.htm"), .html)
    XCTAssertEqual(lang("a.yml"), .yaml)
    XCTAssertEqual(lang("a.zsh"), .bash)
    XCTAssertEqual(lang("Dockerfile"), .dockerfile)
    XCTAssertEqual(lang("Dockerfile.dev"), .dockerfile)
    XCTAssertEqual(lang("web.dockerfile"), .dockerfile)
    XCTAssertNil(lang("LICENSE"))
    XCTAssertNil(lang("a.txt"))
  }

  /// 16 文法の queries（highlights・injections）が全部読めて Query に組める。
  func testEveryGrammarResolvesFromBuildProducts() {
    let registry = LanguageRegistry(queriesRoot: Queries.root)
    for grammar in Grammar.allCases {
      let configuration = registry.configuration(for: grammar)
      XCTAssertNotNil(configuration, "\(grammar) の queries が解けない（\(Queries.root.path)）")
      XCTAssertNotNil(configuration?.queries[.highlights], "\(grammar) に highlights が無い")
      if grammar.injectionFile != nil {
        XCTAssertNotNil(configuration?.queries[.injections], "\(grammar) に injections が無い")
      }
    }
    XCTAssertNotNil(registry.languageProvider("markdown_inline"))
    XCTAssertNotNil(registry.languageProvider("ts"))
    XCTAssertNil(registry.languageProvider("regex"), "持たない言語は nil（injection は無視される）")
  }

  func testMissingRootMeansNoColors() {
    XCTAssertNil(LanguageRegistry(queriesRoot: nil).configuration(for: SyntaxLanguage.swift))
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("orbe-no-queries")
    XCTAssertNil(LanguageRegistry(queriesRoot: empty).configuration(for: SyntaxLanguage.swift))
  }
}
