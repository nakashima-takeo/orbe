import XCTest

@testable import Orbe

/// 種別 → 見た目の表: 15 言語は色相付き、未知は拡張子の頭文字の mono、拡張子無しは `·`。
final class FileChipTests: OrbeTestCase {
  func testKnownLanguagesGetAHueAndUnknownFallBackToTheExtension() {
    XCTAssertEqual(
      FileChip.resolve(URL(fileURLWithPath: "/x/a.swift")), FileChip(glyph: "S", hue: .orange))
    XCTAssertEqual(
      FileChip.resolve(URL(fileURLWithPath: "/x/a.md")), FileChip(glyph: "M↓", hue: .blue))
    XCTAssertEqual(
      FileChip.resolve(URL(fileURLWithPath: "/x/a.json")), FileChip(glyph: "{}", hue: .yellow))
    XCTAssertEqual(
      FileChip.resolve(URL(fileURLWithPath: "/x/Dockerfile")), FileChip(glyph: "D", hue: .teal))
    XCTAssertEqual(
      FileChip.resolve(URL(fileURLWithPath: "/x/a.txt")), FileChip(glyph: "T", hue: nil))
    XCTAssertEqual(
      FileChip.resolve(URL(fileURLWithPath: "/x/Makefile")), FileChip(glyph: "·", hue: nil))
  }

  /// 16 のときの 3 種（S 10 / M↓ 8 / {} 9）を規則で再現し、14 / 12 へは比例して丸める。
  func testGlyphSizeScalesWithTheChip() {
    XCTAssertEqual(FileChip(glyph: "S", hue: .orange).fontSize(for: 16), 10)
    XCTAssertEqual(FileChip(glyph: "M↓", hue: .blue).fontSize(for: 16), 8)
    XCTAssertEqual(FileChip(glyph: "{}", hue: .yellow).fontSize(for: 16), 9)
    XCTAssertEqual(FileChip(glyph: "TS", hue: .sky).fontSize(for: 16), 8)
    XCTAssertEqual(FileChip(glyph: "S", hue: .orange).fontSize(for: 14), 9)
    XCTAssertEqual(FileChip(glyph: "{}", hue: .yellow).fontSize(for: 14), 8)
    XCTAssertEqual(FileChip(glyph: "TS", hue: .sky).fontSize(for: 14), 7)
    XCTAssertEqual(FileChip(glyph: "S", hue: .orange).fontSize(for: 12), 8)
    XCTAssertEqual(FileChip(glyph: "{}", hue: .yellow).fontSize(for: 12), 7)
    XCTAssertEqual(FileChip(glyph: "TS", hue: .sky).fontSize(for: 12), 6)
  }
}
