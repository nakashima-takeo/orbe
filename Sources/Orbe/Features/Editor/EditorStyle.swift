import AppKit
import OrbeEditorCore
import OrbeEditorEngine
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
      selectionColor: .selectedTextBackgroundColor,
      inactiveSelectionColor: .unemphasizedSelectedTextBackgroundColor,
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

  /// 1 行で描く上限を越えて打ち切った行の末尾の印（「ほか 1.2万字」）。数は 1 万（英語は千）以上を 1 桁の小数で略し、
  /// 丸めて次の単位に届けば次の単位で出す（999,999 は「1,000K」でなく「1M」）。
  static func omittedLabel(_ count: Int, language: Language) -> String {
    let ladder: [(unit: Double, suffix: String)] =
      language == .ja
      ? [(10_000, "万"), (100_000_000, "億")] : [(1_000, "K"), (1_000_000, "M"), (1e9, "B")]
    var value = count.formatted(.number.grouping(.automatic))
    var index = ladder.lastIndex { Double(count) >= $0.unit }
    while let i = index {
      let rounded = (Double(count) / ladder[i].unit * 10).rounded() / 10
      if i + 1 < ladder.count, rounded * ladder[i].unit >= ladder[i + 1].unit {
        index = i + 1
        continue
      }
      value = rounded.formatted(.number.precision(.fractionLength(0...1))) + ladder[i].suffix
      index = nil
    }
    return L10n.format(.editorOmittedCharacters, language, value)
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
  static func fill(_ alpha: Double) -> NSColor {
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

/// 文書を開く時点のテキストエンジンの選び方（隠れた設定 3 つと UI の言語から）。
struct EditorEngineChoice {
  /// 新しい面（Metal）で開く。Metal の装置が取れなければ今の面で開く。
  var metal: Bool
  var elasticScroll: Bool
  var fontSmoothing: Bool
  var language: Language

  /// 今の面（STTextView）。テストと fixture の既定。
  static let stTextView = EditorEngineChoice(
    metal: false, elasticScroll: true, fontSmoothing: true, language: .systemDefault)
}

/// セッションが文書を開くときに使う、queries の所在と面の作り方。テキストエンジン（OrbeEditorText・
/// OrbeEditorEngine）と合成する唯一の場所。テストは fake の面を作るものを渡せる。
struct EditorSurfaces {
  let registry: LanguageRegistry
  let make: @MainActor (String) -> any TextSurface
  /// 新しい面を使うと決まっていれば、描画のスレッドとシェーダを裏で先に用意する（実効設定を反映するたびに呼ばれる）
  /// ——最初の面を出すときにシェーダのコンパイルの待ちを見せない。
  let prepare: @MainActor () -> Void

  init(
    registry: LanguageRegistry, make: @escaping @MainActor (String) -> any TextSurface,
    prepare: @escaping @MainActor () -> Void = {}
  ) {
    self.registry = registry
    self.make = make
    self.prepare = prepare
  }

  /// 本物の面を、指定の根の queries で組む。どちらのエンジンで作るかは、文書を開く時点で `engine` を読んで決める
  /// （開いている文書の面は作り直さない）。
  init(queriesRoot: URL?, engine: @escaping @MainActor () -> EditorEngineChoice = { .stTextView }) {
    self.init(
      registry: LanguageRegistry(queriesRoot: queriesRoot),
      make: { text in
        let choice = engine()
        let style = EditorStyle.make()
        let metal =
          choice.metal
          ? makeMetalTextSurface(
            style: style,
            options: MetalTextSurfaceOptions(
              elasticScroll: choice.elasticScroll, fontSmoothing: choice.fontSmoothing,
              omittedLabel: { [language = choice.language] in
                EditorStyle.omittedLabel($0, language: language)
              })) : nil
        return metal ?? makeTextSurface(style: style, text: text)
      },
      prepare: {
        if engine().metal { prepareMetalTextEngine() }
      })
  }

  /// 今の面で開く組成。queries は `.app` の同梱物（`BundledResources.root` 直下の資源バンドル）から解く。
  static let shared = EditorSurfaces(queriesRoot: BundledResources.root)
}
