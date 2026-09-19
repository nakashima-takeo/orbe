import AppKit
import OrbeEditorCore
import OrbeEditorText

/// エディターの見え方を `Theme` から組む唯一の場所。
enum EditorStyle {
  /// 印のバーと三角の不透明度（見本 tint(diffAdd, 0.85)）。
  static let markAlpha: CGFloat = 0.85
  /// インデント線の塗り（見本 fill(0.06)。light は `Theme.Opacity.editorFillLight` を掛ける）。
  static let indentGuideAlpha = 0.06

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
      roleColors: [
        .keyword: Theme.Color.syntaxKeyword,
        .keywordControl: Theme.Color.syntaxKeywordControl,
        .type: Theme.Color.syntaxType,
        .function: Theme.Color.syntaxFunction,
        .string: Theme.Color.syntaxString,
        .comment: Theme.Color.syntaxComment,
        .variable: Theme.Color.syntaxVariable,
        .punctuation: Theme.Color.syntaxPunctuation,
      ],
      marks: TextSurfaceStyle.Marks(
        gutterWidth: Theme.Layout.editorMarkGutter, barWidth: 3, barInset: 2, barRadius: 1,
        triangleSize: 6, added: Theme.Color.diffAdded.withAlphaComponent(markAlpha),
        modified: Theme.Color.diffModified.withAlphaComponent(markAlpha),
        removed: Theme.Color.diffRemoved.withAlphaComponent(markAlpha)),
      decorations: TextSurfaceStyle.Decorations(
        indentGuideColor: fill(indentGuideAlpha), indentGuideWidth: 1,
        whitespaceColor: Theme.Color.editorWhitespace, whitespaceDiameter: 2,
        linkUnderlineThickness: 1, linkUnderlineOffset: 3))
  }

  /// 見本の fill(α) を外観で換算した塗り（`EditorInk.fill` の NSColor 版）。
  private static func fill(_ alpha: Double) -> NSColor {
    NSColor(name: nil) { appearance in
      let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      return Theme.Color.surfaceInk.withAlphaComponent(
        dark ? alpha : alpha * Theme.Opacity.editorFillLight)
    }
  }
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
