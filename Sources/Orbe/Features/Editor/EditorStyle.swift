import AppKit
import OrbeEditorCore
import OrbeEditorText

/// エディターの見え方を `Theme` から組む唯一の場所。
enum EditorStyle {
  /// 印のバーと三角の不透明度（見本 tint(diffAdd, 0.85)）。
  private static let markAlpha: CGFloat = 0.85
  /// インデント線の塗り（見本 fill(0.06)。light は `Theme.Opacity.editorFillLight` を掛ける）。
  private static let indentGuideAlpha: Double = 0.06

  static func make() -> TextSurfaceStyle {
    TextSurfaceStyle(
      font: Theme.Typography.editorCode,
      lineHeight: Theme.Typography.editorLineHeight,
      topInset: Theme.Space.tick,
      textColor: Theme.Color.editorText,
      caretColor: Theme.Color.accentBright,
      caretSize: CGSize(width: 1.5, height: 14),
      gutterFont: Theme.Typography.editorLineNumber,
      gutterTextColor: Theme.Color.editorLineNumber,
      gutterWidth: Theme.Layout.editorLineNumberGutter,
      gutterTrailingInset: Theme.Space.step,
      roleColors: roleColors,
      marks: TextSurfaceStyle.Marks(
        gutterWidth: Theme.Layout.editorMarkGutter, barWidth: 3, barInset: 2, barRadius: 1,
        triangleSize: 6, added: Theme.Color.diffAdded.withAlphaComponent(markAlpha),
        modified: Theme.Color.diffModified.withAlphaComponent(markAlpha),
        removed: Theme.Color.diffRemoved.withAlphaComponent(markAlpha)),
      decorations: TextSurfaceStyle.Decorations(
        indentGuideColor: fill(indentGuideAlpha), indentGuideWidth: 1,
        whitespaceColor: Theme.Color.editorWhitespace, whitespaceDiameter: 2,
        linkUnderlineThickness: 1, linkUnderlineOffset: 3),
      highlights: TextSurfaceStyle.Highlights(
        findMatch: Theme.Color.editorFindMatch,
        currentFindMatch: Theme.Color.editorFindMatchCurrent,
        currentFindLine: Theme.Color.editorFindLine,
        selectionOccurrence: Theme.Color.editorSelectionOccurrence,
        selectionOccurrenceInactive: scaledAlpha(Theme.Color.editorSelectionOccurrence, 0.5),
        wordOccurrence: Theme.Color.editorWordOccurrence))
  }

  /// 役割ごとの文字色（本文とミニマップが共有する）。
  static let roleColors: [SyntaxRole: NSColor] = [
    .keyword: Theme.Color.syntaxKeyword,
    .keywordControl: Theme.Color.syntaxKeywordControl,
    .type: Theme.Color.syntaxType,
    .function: Theme.Color.syntaxFunction,
    .string: Theme.Color.syntaxString,
    .comment: Theme.Color.syntaxComment,
    .variable: Theme.Color.syntaxVariable,
    .punctuation: Theme.Color.syntaxPunctuation,
  ]

  /// ミニマップの見え方（VS Code の既定。色は Dark Modern / Light Modern、git は Orbe の diff.*）。
  static func minimap() -> MinimapStyle {
    MinimapStyle(
      textColor: Theme.Color.editorText, roleColors: roleColors,
      slider: Theme.Color.editorMinimapSlider, sliderHover: Theme.Color.editorMinimapSliderHover,
      sliderActive: Theme.Color.editorMinimapSliderActive,
      selection: NSColor.selectedTextBackgroundColor, findMatch: Theme.Color.editorFindMatch,
      wordOccurrence: Theme.Color.editorSelectionOccurrence, added: Theme.Color.diffAdded,
      modified: Theme.Color.diffModified, removed: Theme.Color.diffRemoved)
  }

  /// スクロールバーと印の見え方。git の印は diff.* α .6、キャレットの印はキャレット色 α .7（VS Code と同じ α）。
  static func scrollbar() -> ScrollbarStyle {
    ScrollbarStyle(
      border: hairline(0.07), slider: Theme.Color.editorScrollbarSlider,
      sliderHover: Theme.Color.editorScrollbarSliderHover,
      sliderActive: Theme.Color.editorScrollbarSliderActive,
      findMatch: Theme.Color.editorRulerFind, wordOccurrence: Theme.Color.editorRulerOccurrence,
      added: Theme.Color.diffAdded.withAlphaComponent(0.6),
      modified: Theme.Color.diffModified.withAlphaComponent(0.6),
      removed: Theme.Color.diffRemoved.withAlphaComponent(0.6),
      caret: Theme.Color.accentBright.withAlphaComponent(0.7))
  }

  /// 見本の fill(α) を外観で換算した塗り（`EditorInk.fill` の NSColor 版。換算は `EditorInk.fillAlpha`）。
  private static func fill(_ alpha: Double) -> NSColor {
    NSColor(name: nil) { appearance in
      Theme.Color.surfaceInk.withAlphaComponent(
        EditorInk.fillAlpha(alpha, dark: isDark(appearance)))
    }
  }

  /// 見本の hairline(α) を外観で換算した縁（`EditorInk.hairline` の NSColor 版）。
  private static func hairline(_ alpha: Double) -> NSColor {
    NSColor(name: nil) { appearance in
      Theme.Color.borderInk.withAlphaComponent(
        isDark(appearance) ? alpha : alpha * Theme.Opacity.editorHairlineLight)
    }
  }

  /// 外観ごとの α に `factor` を掛けた色。
  private static func scaledAlpha(_ color: NSColor, _ factor: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
      var resolved = color
      appearance.performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB) ?? color
      }
      return resolved.withAlphaComponent(resolved.alphaComponent * factor)
    }
  }

  private static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }
}

/// ミニマップの見え方。色は α 込みの名前付き NSColor（外観は描画時に解く）。
struct MinimapStyle {
  let textColor: NSColor
  let roleColors: [SyntaxRole: NSColor]
  let slider: NSColor
  let sliderHover: NSColor
  let sliderActive: NSColor
  let selection: NSColor
  let findMatch: NSColor
  let wordOccurrence: NSColor
  let added: NSColor
  let modified: NSColor
  let removed: NSColor
  /// 字の明るさの係数（VS Code `MinimapCharRenderer` の soften。dark 12/15・light 50/60）と、全体の不透明度。
  let darkGlyphRatio: CGFloat = 12.0 / 15
  let lightGlyphRatio: CGFloat = 50.0 / 60
  let opacity: CGFloat = 0.9
}

/// スクロールバー（印を載せる）の見え方。
struct ScrollbarStyle {
  let border: NSColor
  let slider: NSColor
  let sliderHover: NSColor
  let sliderActive: NSColor
  let findMatch: NSColor
  let wordOccurrence: NSColor
  let added: NSColor
  let modified: NSColor
  let removed: NSColor
  let caret: NSColor
}

/// セッションが文書を開くときに使う、queries の所在と面の作り方。テキストエンジン（OrbeEditorText）と
/// 合成する唯一の場所。テストは fake の面を作るものを渡せる。
struct EditorSurfaces {
  let registry: LanguageRegistry
  let make: @MainActor (String) -> any TextSurface

  init(registry: LanguageRegistry, make: @escaping @MainActor (String) -> any TextSurface) {
    self.registry = registry
    self.make = make
  }

  /// 本物の面（テキストエンジン）を、指定の根の queries で組む。URL の ⌘クリックは既定ブラウザへ
  /// （行き先を決めるのはエンジンでなくここ）。
  init(queriesRoot: URL?) {
    self.init(
      registry: LanguageRegistry(queriesRoot: queriesRoot),
      make: {
        let surface = makeTextSurface(style: EditorStyle.make(), text: $0)
        surface.onOpenLink = { NSWorkspace.shared.open($0) }
        return surface
      })
  }

  /// 本番の組成。queries は `.app` の同梱物（`BundledResources.root` 直下の資源バンドル）から解く。
  static let shared = EditorSurfaces(queriesRoot: BundledResources.root)
}
