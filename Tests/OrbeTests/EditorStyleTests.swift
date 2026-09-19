import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 見え方の唯一の決定点——テキストエンジンへ渡る寸法が見本「コード本体」の値であること、
/// 8 役割すべてに互いに違う色が付き、その色が外観（dark / light）で解き直されること。
///
/// 壊れると何が起きるか。寸法が変われば見本との突合は人が gallery を見るまで気づかない。
/// 役割の色が欠けるとその役割は素の文字色で描かれ（keyword と変数が同じ色になる）、
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

  /// 見本の寸法（mono 12 / 行高 18 / 上端 4 / 行番号 mono 11・幅 50・右 8 / キャレット 1.5×14）。
  func testMetricsMatchTheDesignSample() {
    let style = EditorStyle.make()
    XCTAssertEqual(style.font.pointSize, 12)
    XCTAssertEqual(style.lineHeight, 18)
    XCTAssertEqual(style.topInset, 4)
    XCTAssertEqual(style.gutterFont.pointSize, 11)
    XCTAssertEqual(style.gutterWidth, 50)
    XCTAssertEqual(style.gutterTrailingInset, 8)
    XCTAssertEqual(style.caretSize, CGSize(width: 1.5, height: 14))
    XCTAssertEqual(style.marks.gutterWidth, 19)
    XCTAssertEqual(style.marks.barWidth, 3)
    XCTAssertEqual(style.marks.barInset, 2)
    XCTAssertEqual(style.marks.barRadius, 1)
    XCTAssertEqual(style.marks.triangleSize, 6)
    XCTAssertEqual(style.decorations.indentGuideWidth, 1)
    XCTAssertEqual(style.decorations.whitespaceDiameter, 2)
    XCTAssertEqual(style.decorations.linkUnderlineThickness, 1)
    XCTAssertEqual(style.decorations.linkUnderlineOffset, 3)
    XCTAssertEqual(style.decorations.searchMatchRadius, 2)
    let overview = EditorStyle.overview()
    XCTAssertEqual(overview.minimapWidth, 100)
    XCTAssertEqual(overview.marksWidth, 13)
    XCTAssertEqual(overview.rowHeight, 2)
    XCTAssertEqual(overview.pitch, 4)
    XCTAssertEqual(overview.columnWidth, 0.55)
    XCTAssertEqual(overview.indentWidth, 1.1)
    XCTAssertEqual(overview.maxRowExtent, 72)
    XCTAssertEqual(overview.topInset, 6)
    XCTAssertEqual(overview.leadingInset, 8)
  }

  /// 装備の色——印の 3 色は diff トークンの α .85、インデント線は surfaceInk の .06（light は ×0.6）、丸点は
  /// text.muted の .55——で、どれも外観で解き直される。
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
      try XCTUnwrap(resolved(style.decorations.indentGuideColor, .darkAqua)).alphaComponent, 0.06,
      accuracy: 0.001)
    XCTAssertEqual(
      try XCTUnwrap(resolved(style.decorations.indentGuideColor, .aqua)).alphaComponent, 0.036,
      accuracy: 0.001)
    XCTAssertEqual(
      try XCTUnwrap(resolved(style.decorations.whitespaceColor, .darkAqua)).alphaComponent, 0.55,
      accuracy: 0.01)
    XCTAssertEqual(
      try XCTUnwrap(resolved(style.decorations.searchMatchColor, .darkAqua)).alphaComponent, 0.30,
      accuracy: 0.01)
    XCTAssertNotEqual(
      try XCTUnwrap(resolved(style.decorations.searchMatchColor, .darkAqua)),
      try XCTUnwrap(resolved(style.decorations.searchMatchColor, .aqua)))
  }

  /// 俯瞰の色——帯 .07・行 .15・コメント行 .40・ミニマップの印 .9・印の列 .8・カーソル .7——で、縁は hairline の
  /// .07（light は ×1.4）。どれも外観で解き直される。
  func testOverviewColorsCarryTheSampleAlphasAndFollowTheAppearance() throws {
    let overview = EditorStyle.overview()
    let expected: [(NSColor, CGFloat)] = [
      (overview.band, 0.07), (overview.row, 0.15), (overview.commentRow, 0.40),
      (overview.minimapAdded, 0.9), (overview.minimapModified, 0.9), (overview.marksAdded, 0.8),
      (overview.marksModified, 0.8), (overview.caret, 0.7), (overview.border, 0.07),
    ]
    for (color, alpha) in expected {
      XCTAssertEqual(
        try XCTUnwrap(resolved(color, .darkAqua)).alphaComponent, alpha, accuracy: 0.005)
      XCTAssertNotEqual(
        try XCTUnwrap(resolved(color, .darkAqua)), try XCTUnwrap(resolved(color, .aqua)))
    }
    XCTAssertEqual(
      try XCTUnwrap(resolved(overview.border, .aqua)).alphaComponent, 0.098, accuracy: 0.001)
    let marks = [
      (overview.minimapAdded, Theme.Color.diffAdded), (overview.marksAdded, Theme.Color.diffAdded),
      (overview.minimapModified, Theme.Color.diffModified),
      (overview.marksModified, Theme.Color.diffModified),
    ]
    for (mark, token) in marks {
      for appearance in [NSAppearance.Name.darkAqua, .aqua] {
        let resolved = try XCTUnwrap(self.resolved(mark, appearance))
        let base = try XCTUnwrap(self.resolved(token, appearance))
        XCTAssertEqual(resolved.redComponent, base.redComponent, accuracy: 0.002, "追加は緑・変更は青")
        XCTAssertEqual(resolved.greenComponent, base.greenComponent, accuracy: 0.002)
        XCTAssertEqual(resolved.blueComponent, base.blueComponent, accuracy: 0.002)
      }
    }
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
}
