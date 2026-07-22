import XCTest

@testable import Orbe

/// `OpenURL.resolve` の分岐を固定する。scheme を持つ URL はそのまま、
/// scheme 無しはファイルパスとみなし `~` を展開する（ghostty-org/ghostty#8763）。
final class OpenURLResolverTests: XCTestCase {
  func testSchemeURLPassesThrough() {
    let https = OpenURL.resolve("https://example.com/a?b=1")
    XCTAssertEqual(https.scheme, "https")
    XCTAssertEqual(https.absoluteString, "https://example.com/a?b=1")
    XCTAssertEqual(OpenURL.resolve("mailto:a@example.com").scheme, "mailto")
  }

  func testSchemelessAbsolutePathBecomesFileURL() {
    let url = OpenURL.resolve("/etc/hosts")
    XCTAssertTrue(url.isFileURL)
    XCTAssertEqual(url.path, "/etc/hosts")
  }

  func testTildeExpandsToHome() {
    let home = NSHomeDirectory()
    let url = OpenURL.resolve("~/Documents/file.txt")
    XCTAssertTrue(url.isFileURL)
    XCTAssertEqual(url.path, "\(home)/Documents/file.txt")
  }

  func testBareHostWithoutSchemeIsFilePath() {
    // scheme を持たない "example.com" はファイルパス扱い（誤ってスキーム化しない）。
    XCTAssertTrue(OpenURL.resolve("example.com").isFileURL)
  }
}
