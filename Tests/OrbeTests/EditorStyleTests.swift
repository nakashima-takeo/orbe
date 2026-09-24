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
  }

  /// 強調と俯瞰の色は VS Code Dark Modern / Light Modern の値（sRGB・α）。選択文字列の出現は焦点が無いとき α 半分。
  func testHighlightAndOverviewColorsAreTheVSCodeValues() throws {
    let highlights = EditorStyle.make().highlights
    let minimap = EditorStyle.minimap()
    let scrollbar = EditorStyle.scrollbar()
    let expected: [Expected] = [
      .init(highlights.findMatch, dark: (0xea5c00, 0.33), light: (0xea5c00, 0.33)),
      .init(highlights.currentFindMatch, dark: (0x9e6a03, 1), light: (0xa8ac94, 1)),
      .init(highlights.currentFindLine, dark: (0xffffff, 0.043), light: (0xfdff00, 0.2)),
      .init(highlights.selectionOccurrence, dark: (0xadd6ff, 0.15), light: (0xadd6ff, 0.5)),
      .init(
        highlights.selectionOccurrenceInactive, dark: (0xadd6ff, 0.075), light: (0xadd6ff, 0.25)),
      .init(highlights.wordOccurrence, dark: (0x575757, 0.72), light: (0x575757, 0.25)),
      .init(minimap.slider, dark: (0x797979, 0.2), light: (0x646464, 0.2)),
      .init(minimap.sliderHover, dark: (0x646464, 0.35), light: (0x646464, 0.35)),
      .init(minimap.sliderActive, dark: (0xbfbfbf, 0.2), light: (0x000000, 0.3)),
      .init(minimap.findMatch, dark: (0xea5c00, 0.33), light: (0xea5c00, 0.33)),
      .init(minimap.wordOccurrence, dark: (0xadd6ff, 0.15), light: (0xadd6ff, 0.5)),
      .init(scrollbar.slider, dark: (0x797979, 0.4), light: (0x646464, 0.4)),
      .init(scrollbar.sliderHover, dark: (0x646464, 0.7), light: (0x646464, 0.7)),
      .init(scrollbar.sliderActive, dark: (0xbfbfbf, 0.4), light: (0x000000, 0.6)),
      .init(scrollbar.findMatch, dark: (0xd18616, 0.49), light: (0xd18616, 0.49)),
      .init(scrollbar.wordOccurrence, dark: (0xa0a0a0, 0.8), light: (0xa0a0a0, 0.8)),
    ]
    for item in expected {
      for (appearance, (hex, alpha)) in [
        (NSAppearance.Name.darkAqua, item.dark), (.aqua, item.light),
      ] {
        let got = try XCTUnwrap(resolved(item.color, appearance))
        XCTAssertEqual(got.redComponent, CGFloat((hex >> 16) & 0xff) / 255, accuracy: 0.003)
        XCTAssertEqual(got.greenComponent, CGFloat((hex >> 8) & 0xff) / 255, accuracy: 0.003)
        XCTAssertEqual(got.blueComponent, CGFloat(hex & 0xff) / 255, accuracy: 0.003)
        XCTAssertEqual(got.alphaComponent, alpha, accuracy: 0.003)
      }
    }
  }

  /// 期待する色（外観ごとの sRGB と α）。
  struct Expected {
    let color: NSColor
    let dark: (Int, CGFloat)
    let light: (Int, CGFloat)

    init(_ color: NSColor, dark: (Int, CGFloat), light: (Int, CGFloat)) {
      self.color = color
      self.dark = dark
      self.light = light
    }
  }

  /// 期待する印の色（元のトークンと α）。
  struct Mark {
    let color: NSColor
    let token: NSColor
    let alpha: CGFloat

    init(_ color: NSColor, _ token: NSColor, _ alpha: CGFloat) {
      self.color = color
      self.token = token
      self.alpha = alpha
    }
  }

  /// 俯瞰の git の印は Orbe の diff.*（ミニマップは α 1、スクロールバーは VS Code の α .6）、キャレットの印はキャレット色
  /// α .7、スクロールバーの縁は hairline .07（light ×1.4）。
  func testOverviewGitCaretAndBorderColorsUseTheOrbeTokens() throws {
    let minimap = EditorStyle.minimap()
    let scrollbar = EditorStyle.scrollbar()
    let marks: [Mark] = [
      .init(minimap.added, Theme.Color.diffAdded, 1),
      .init(minimap.modified, Theme.Color.diffModified, 1),
      .init(minimap.removed, Theme.Color.diffRemoved, 1),
      .init(scrollbar.added, Theme.Color.diffAdded, 0.6),
      .init(scrollbar.modified, Theme.Color.diffModified, 0.6),
      .init(scrollbar.removed, Theme.Color.diffRemoved, 0.6),
      .init(scrollbar.caret, Theme.Color.accentBright, 0.7),
    ]
    for item in marks {
      for appearance in [NSAppearance.Name.darkAqua, .aqua] {
        let got = try XCTUnwrap(resolved(item.color, appearance))
        let base = try XCTUnwrap(resolved(item.token, appearance))
        XCTAssertEqual(got.alphaComponent, item.alpha, accuracy: 0.005)
        XCTAssertEqual(got.redComponent, base.redComponent, accuracy: 0.002)
        XCTAssertEqual(got.greenComponent, base.greenComponent, accuracy: 0.002)
        XCTAssertEqual(got.blueComponent, base.blueComponent, accuracy: 0.002)
      }
    }
    XCTAssertEqual(
      try XCTUnwrap(resolved(scrollbar.border, .darkAqua)).alphaComponent, 0.07, accuracy: 0.001)
    XCTAssertEqual(
      try XCTUnwrap(resolved(scrollbar.border, .aqua)).alphaComponent, 0.098, accuracy: 0.001)
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
