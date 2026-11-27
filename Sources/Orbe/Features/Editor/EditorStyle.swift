import AppKit
import OrbeEditorCore
import OrbeEditorEngine

/// エディターの見え方を `Theme` から組む唯一の場所。
enum EditorStyle {
  /// 印のバーと三角の不透明度（diff 色の 0.85）。
  private static let markAlpha: CGFloat = 0.85

  static func make() -> TextSurfaceStyle {
    TextSurfaceStyle(
      font: Theme.Typography.editorCode,
      lineHeight: Theme.Typography.editorLineHeight,
      topInset: Theme.Space.tick,
      textColor: Theme.Color.editorText,
      backgroundColor: Theme.Color.bgBase,
      caretColor: Theme.Color.accentBright,
      caretSize: CGSize(width: 1.5, height: 14),
      selectionColor: Theme.Color.editorSelection,
      inactiveSelectionColor: Theme.Color.editorSelectionInactive,
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
        whitespaceColor: Theme.Color.editorWhitespace, whitespaceDiameter: 2,
        linkUnderlineThickness: 1, linkUnderlineOffset: 3),
      highlights: TextSurfaceStyle.Highlights(
        findMatch: Theme.Color.editorFindMatch,
        currentFindMatch: Theme.Color.editorFindMatchCurrent,
        currentFindLine: Theme.Color.editorFindLine,
        selectionOccurrence: Theme.Color.editorSelectionOccurrence,
        selectionOccurrenceInactive: scaledAlpha(Theme.Color.editorSelectionOccurrence, 0.5),
        wordOccurrence: Theme.Color.editorWordOccurrence),
      overview: overview())
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

  /// 俯瞰の見え方（VS Code の既定。色は Dark Modern / Light Modern、git は Orbe の diff.*——ミニマップは α 1、スクロール
  /// バーの印は VS Code と同じ α .6。キャレットの印はキャレット色 α .7）。
  private static func overview() -> TextSurfaceStyle.Overview {
    TextSurfaceStyle.Overview(
      minimap: TextSurfaceStyle.Minimap(
        maxWidth: Theme.Layout.editorMinimapMaxWidth, slider: Theme.Color.editorMinimapSlider,
        sliderHover: Theme.Color.editorMinimapSliderHover,
        sliderActive: Theme.Color.editorMinimapSliderActive,
        selection: Theme.Color.editorSelection, findMatch: Theme.Color.editorFindMatch,
        wordOccurrence: Theme.Color.editorSelectionOccurrence, added: Theme.Color.diffAdded,
        modified: Theme.Color.diffModified, removed: Theme.Color.diffRemoved),
      scrollbar: TextSurfaceStyle.Scrollbar(
        width: Theme.Layout.editorScrollbar,
        horizontalHeight: Theme.Layout.editorHorizontalScrollbar,
        slider: Theme.Color.editorScrollbarSlider,
        sliderHover: Theme.Color.editorScrollbarSliderHover,
        sliderActive: Theme.Color.editorScrollbarSliderActive, border: hairline(0.07),
        findMatch: Theme.Color.editorRulerFind, wordOccurrence: Theme.Color.editorRulerOccurrence,
        added: Theme.Color.diffAdded.withAlphaComponent(0.6),
        modified: Theme.Color.diffModified.withAlphaComponent(0.6),
        removed: Theme.Color.diffRemoved.withAlphaComponent(0.6),
        caret: Theme.Color.accentBright.withAlphaComponent(0.7)),
      topShadow: Theme.Color.editorScrollShadow, minimapShadow: Theme.Color.editorMinimapShadow,
      fadeIn: Theme.Motion.editorSliderFadeIn, fadeOut: Theme.Motion.editorScrollbarFadeOut,
      hideDelay: Theme.Motion.editorScrollbarHideDelay)
  }

  /// `fill(α)` を外観で換算した塗り（`EditorInk.fill` の NSColor 版。換算は `EditorInk.fillAlpha`）。
  static func fill(_ alpha: Double) -> NSColor {
    NSColor(name: nil) { appearance in
      Theme.Color.surfaceInk.withAlphaComponent(
        EditorInk.fillAlpha(alpha, dark: isDark(appearance)))
    }
  }

  /// `hairline(α)` を外観で換算した縁（`EditorInk.hairline` の NSColor 版）。
  static func hairline(_ alpha: Double) -> NSColor {
    NSColor(name: nil) { appearance in
      Theme.Color.borderInk.withAlphaComponent(
        isDark(appearance) ? alpha : alpha * Theme.Opacity.editorHairlineLight)
    }
  }

  /// `sunk(α)` を外観で換算した沈み面（`EditorInk.sunk` の NSColor 版）。
  static func sunk(_ alpha: Double) -> NSColor {
    NSColor(name: nil) { appearance in
      Theme.Color.sunkInk.withAlphaComponent(
        isDark(appearance) ? alpha : alpha * Theme.Opacity.editorSunkLight)
    }
  }

  /// 外観ごとの α に `factor` を掛けた色。
  static func scaledAlpha(_ color: NSColor, _ factor: CGFloat) -> NSColor {
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

/// テキスト面を作れず、文書を開けない（Metal の装置が取れない）。
enum EditorSurfaceError: Error, Equatable {
  case noMetalDevice
}

/// セッションが文書を開くときに使う、queries の所在と面の作り方。テキストエンジン（OrbeEditorEngine）と合成する唯一の
/// 場所。テストは fake の面を作るものを渡せる。
struct EditorSurfaces {
  let registry: LanguageRegistry
  /// 面を作る。作れなければ nil（文書は開けない）。
  let make: @MainActor () -> (any TextSurface)?
  /// 描画のスレッドとシェーダを裏で先に用意する（エディター面が初めて見えたときに呼ばれる。何度呼んでもよい）——最初の
  /// 面を出すときにシェーダのコンパイルの待ちを見せない。
  let prepare: @MainActor () -> Void
  /// 面の上に描く文言（打ち切った行の印・PR のスレッド）の言語。
  let language: @MainActor () -> Language

  init(
    registry: LanguageRegistry, make: @escaping @MainActor () -> (any TextSurface)?,
    prepare: @escaping @MainActor () -> Void = {},
    language: @escaping @MainActor () -> Language = { .systemDefault }
  ) {
    self.registry = registry
    self.make = make
    self.prepare = prepare
    self.language = language
  }

  /// 本物の面を、指定の根の queries で組む。打ち切った行の印の文言は面を作る時点の UI の言語（`language`）で、印の数の
  /// 書き方は面を作る時点の地域で決まる。
  init(
    queriesRoot: URL?, language: @escaping @MainActor () -> Language = { .systemDefault }
  ) {
    self.init(
      registry: LanguageRegistry(queriesRoot: queriesRoot),
      make: {
        let label = EditorStyle.OmittedLabel(language: language(), locale: .current)
        return makeMetalTextSurface(style: EditorStyle.make(), omittedLabel: { label($0) })
      },
      prepare: prepareMetalTextEngine, language: language)
  }

  /// queries は `.app` の同梱物（`BundledResources.root` 直下の資源バンドル）から解く。
  static let shared = EditorSurfaces(queriesRoot: BundledResources.root)
}

/// テキスト面の view は、変換中の ⌘ キーを IME へ先に渡す窓の根の口に答える。
extension TextSurfaceInputView: InputMethodKeyEquivalents {}
