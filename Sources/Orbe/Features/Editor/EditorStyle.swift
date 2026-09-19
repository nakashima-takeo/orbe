import AppKit
import OrbeEditorCore
import OrbeEditorText

/// エディターの見え方を `Theme` から組む唯一の場所。
enum EditorStyle {
  /// 印のバーと三角の不透明度（見本 tint(diffAdd, 0.85)）。
  private static let markAlpha: CGFloat = 0.85
  /// インデント線の塗り（見本 fill(0.06)。light は `Theme.Opacity.editorFillLight` を掛ける）。
  private static let indentGuideAlpha: Double = 0.06
  /// ファイル内検索の一致の地（見本 SearchPanel のヒット tint(modified, 0.30)）。
  private static let searchMatchAlpha: CGFloat = 0.30

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
        linkUnderlineThickness: 1, linkUnderlineOffset: 3,
        searchMatchColor: Theme.Color.editorModified.withAlphaComponent(searchMatchAlpha),
        searchMatchRadius: 2))
  }

  /// 俯瞰（見本 CodeView.tsx のミニマップと印の列）の見え方。
  static func overview() -> OverviewStyle {
    OverviewStyle(
      minimapWidth: Theme.Layout.editorMinimap, marksWidth: Theme.Layout.editorScrollMarks,
      border: hairline(0.07), band: Theme.Color.editorText.withAlphaComponent(0.07),
      row: Theme.Color.syntaxPunctuation.withAlphaComponent(0.15),
      commentRow: Theme.Color.syntaxComment.withAlphaComponent(0.40),
      minimapAdded: Theme.Color.diffAdded.withAlphaComponent(0.9),
      minimapModified: Theme.Color.diffModified.withAlphaComponent(0.9),
      marksAdded: Theme.Color.diffAdded.withAlphaComponent(0.8),
      marksModified: Theme.Color.diffModified.withAlphaComponent(0.8),
      caret: Theme.Color.textPrimary.withAlphaComponent(0.7))
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

  private static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }
}

/// 俯瞰の見え方。寸法は見本 `CodeView.tsx` の値（行 2・ピッチ 4・桁 0.55・インデント桁 1.1・上限 72・余白 上 6 左 8
/// 右 4・印の位置）で、色は α 込みの名前付き NSColor（外観は描画時に解く）。
struct OverviewStyle {
  let minimapWidth: CGFloat
  let marksWidth: CGFloat
  /// ミニマップの行の高さと、行ごとの縦のピッチ。
  let rowHeight: CGFloat = 2
  let pitch: CGFloat = 4
  /// 1 桁の幅と、インデント 1 桁の幅、行の右端の上限（左余白から）。
  let columnWidth: CGFloat = 0.55
  let indentWidth: CGFloat = 1.1
  let maxRowExtent: CGFloat = 72
  let rowRadius: CGFloat = 1
  let topInset: CGFloat = 6
  let leadingInset: CGFloat = 8
  /// ミニマップ左端の git 印（x・幅）。
  let minimapMarkX: CGFloat = 1
  let minimapMarkWidth: CGFloat = 2
  /// 印の列の追加／変更のバー（x・幅）とカーソルの印（x・幅・高）。
  let marksBarX: CGFloat = 2
  let marksBarWidth: CGFloat = 4
  let caretMarkX: CGFloat = 6
  let caretMarkWidth: CGFloat = 5
  let caretMarkHeight: CGFloat = 2
  let border: NSColor
  let band: NSColor
  let row: NSColor
  let commentRow: NSColor
  let minimapAdded: NSColor
  let minimapModified: NSColor
  let marksAdded: NSColor
  let marksModified: NSColor
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
