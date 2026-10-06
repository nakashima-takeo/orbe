import XCTest

@testable import OrbeEditorCore

/// capture 名の正規化——最長一致・数値と定数と強調は素の文字色・表に無い名前は plain。
final class CaptureRoleMapTests: XCTestCase {
  func testLongestPrefixWinsAndUnmappedNamesArePlain() {
    XCTAssertEqual(
      CaptureRoleMap.role(for: "keyword.function"), .keyword, "表に無い枝は親の keyword")
    XCTAssertEqual(
      CaptureRoleMap.role(for: "keyword.conditional.ternary"), .keywordControl,
      "最も長く一致する keyword.conditional")
    for name in ["number", "constant", "text.emphasis", "spell"] {
      XCTAssertNil(CaptureRoleMap.role(for: name), name)
    }
  }
}
