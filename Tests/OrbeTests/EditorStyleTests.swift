import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 見え方の唯一の決定点——8 役割すべてに互いに違う色が付き、その色が外観（dark / light）で解き直されること。
///
/// 壊れると何が起きるか。役割の色が欠けるとその役割は素の文字色で描かれ（keyword と変数が同じ色になる）、
/// 色が静的だと light に切り替えたときコードだけ dark の配色のまま残る。
@MainActor
final class EditorStyleTests: OrbeTestCase {
  private func resolved(_ color: NSColor, _ appearance: NSAppearance.Name) -> NSColor? {
    var result: NSColor?
    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
      result = color.usingColorSpace(.sRGB)
    }
    return result
  }

  /// 装備の色——印の 3 色は diff トークンの α .85、丸点は text.muted の .55——で、どれも外観で解き直される。
  func testMarkAndDecorationColorsCarryTheSampleAlphasAndFollowTheAppearance() throws {
    let style = EditorStyle.make()
    let marks = [
      (style.marks.added, Theme.Color.diffAdded), (style.marks.modified, Theme.Color.diffModified),
      (style.marks.removed, Theme.Color.diffRemoved),
    ]
    for (mark, token) in marks {
      for appearance in [NSAppearance.Name.darkAqua, .aqua] {
        let resolved = try XCTUnwrap(self.resolved(mark, appearance))
        let base = try XCTUnwrap(self.resolved(token, appearance))
        XCTAssertEqual(resolved.alphaComponent, 0.85, accuracy: 0.01)
        XCTAssertEqual(resolved.redComponent, base.redComponent, accuracy: 0.002)
        XCTAssertEqual(resolved.greenComponent, base.greenComponent, accuracy: 0.002)
        XCTAssertEqual(resolved.blueComponent, base.blueComponent, accuracy: 0.002)
      }
      XCTAssertNotEqual(
        try XCTUnwrap(resolved(mark, .darkAqua)), try XCTUnwrap(resolved(mark, .aqua)))
    }
    XCTAssertNotEqual(
      try XCTUnwrap(resolved(style.marks.modified, .darkAqua)),
      try XCTUnwrap(resolved(style.marks.added, .darkAqua)), "追加と変更は色で区別する")
    XCTAssertEqual(
      try XCTUnwrap(resolved(style.decorations.whitespaceColor, .darkAqua)).alphaComponent, 0.55,
      accuracy: 0.01)
  }

  /// 8 役割すべてに色があり、同じ外観の中で互いに違い、dark と light で解が変わる。
  func testEveryRoleHasADistinctColorThatFollowsTheAppearance() throws {
    let style = EditorStyle.make()
    var darkValues: Set<String> = []
    for role in SyntaxRole.allCases {
      let color = try XCTUnwrap(style.roleColors[role], "\(role) に色が無い（素の文字色で描かれる）")
      let dark = try XCTUnwrap(resolved(color, .darkAqua))
      let light = try XCTUnwrap(resolved(color, .aqua))
      XCTAssertNotEqual(dark, light, "\(role) の色が外観で解き直されない")
      darkValues.insert("\(dark)")
    }
    XCTAssertEqual(darkValues.count, SyntaxRole.allCases.count, "役割ごとに違う色（取り違えの検知）")
  }

  /// 素の文字・キャレット・行番号も外観で解き直され、行番号だけは沈めた不透明度（見本の tint .55）を持つ。
  func testTextCaretAndLineNumberColorsFollowTheAppearance() throws {
    let style = EditorStyle.make()
    for color in [style.textColor, style.caretColor, style.gutterTextColor] {
      XCTAssertNotEqual(
        try XCTUnwrap(resolved(color, .darkAqua)), try XCTUnwrap(resolved(color, .aqua)))
    }
    XCTAssertEqual(
      try XCTUnwrap(resolved(style.gutterTextColor, .darkAqua)).alphaComponent, 0.55, accuracy: 0.01
    )
    XCTAssertEqual(try XCTUnwrap(resolved(style.textColor, .darkAqua)).alphaComponent, 1)
  }

  /// 打ち切った行の末尾の印の略記——丸めて次の単位に届けば次の単位で出す（「1,000K」「10,000万」にしない）。
  func testOmittedLabelAbbreviatesAtTheUnitBoundaries() {
    func en(_ count: Int) -> String { EditorStyle.omittedLabel(count, language: .en) }
    func ja(_ count: Int) -> String { EditorStyle.omittedLabel(count, language: .ja) }
    XCTAssertEqual(en(999), "999 more")
    XCTAssertEqual(en(999_949), "999.9K more")
    XCTAssertEqual(en(999_950), "1M more")
    XCTAssertEqual(en(999_999), "1M more")
    XCTAssertEqual(en(1_000_000), "1M more")
    XCTAssertEqual(ja(9_999), "ほか \(9_999.formatted(.number.grouping(.automatic)))字")
    XCTAssertEqual(ja(10_000), "ほか 1万字")
    XCTAssertEqual(ja(12_345), "ほか 1.2万字")
    XCTAssertEqual(ja(99_999_999), "ほか 1億字")
  }
}
