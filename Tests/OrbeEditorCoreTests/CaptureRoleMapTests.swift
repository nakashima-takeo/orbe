import XCTest

@testable import OrbeEditorCore

/// capture 名の正規化——最長一致・制御キーワードの分離・表に無い名前は plain。
final class CaptureRoleMapTests: XCTestCase {
  func testLongestPrefixWins() {
    XCTAssertEqual(CaptureRoleMap.role(for: "keyword"), .keyword)
    XCTAssertEqual(CaptureRoleMap.role(for: "keyword.function"), .keyword)
    XCTAssertEqual(CaptureRoleMap.role(for: "keyword.conditional"), .keywordControl)
    XCTAssertEqual(CaptureRoleMap.role(for: "keyword.conditional.ternary"), .keywordControl)
    XCTAssertEqual(CaptureRoleMap.role(for: "keyword.return"), .keywordControl)
    XCTAssertEqual(CaptureRoleMap.role(for: "function.method"), .function)
    XCTAssertEqual(CaptureRoleMap.role(for: "string.special.key"), .string)
    XCTAssertEqual(CaptureRoleMap.role(for: "comment.documentation"), .comment)
    XCTAssertEqual(CaptureRoleMap.role(for: "variable.parameter"), .variable)
    XCTAssertEqual(CaptureRoleMap.role(for: "punctuation.bracket"), .punctuation)
    XCTAssertEqual(CaptureRoleMap.role(for: "type.builtin"), .type)
  }

  func testPlainNames() {
    for name in [
      "number", "number.float", "constant", "label", "none", "spell", "text.emphasis",
      "text.strong",
    ] {
      XCTAssertNil(CaptureRoleMap.role(for: name), name)
    }
    XCTAssertEqual(CaptureRoleMap.role(for: "constant.builtin"), .keyword)
    XCTAssertEqual(CaptureRoleMap.role(for: "text.title"), .keyword)
    XCTAssertEqual(CaptureRoleMap.role(for: "text.literal"), .string)
  }
}
