import AppKit
import OrbeEditorCore
import OrbeEditorText

/// エディターの見え方を `Theme` から組む唯一の場所。フォント設定が入るときはここだけが設定を読み、
/// 開いている面へ `style` を配り直す。
enum EditorStyle {
  static func make() -> TextSurfaceStyle {
    TextSurfaceStyle(
      font: Theme.Typography.editorCode,
      lineHeight: Theme.Typography.editorLineHeight,
      topInset: Theme.Space.tick,
      textColor: Theme.Color.editorCodeText,
      caretColor: Theme.Color.accentBright,
      caretSize: CGSize(width: 1.5, height: 14),
      gutterFont: Theme.Typography.editorLineNumber,
      gutterTextColor: Theme.Color.editorLineNumber,
      gutterWidth: 50,
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
      ])
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

  /// 本物の面（テキストエンジン）を、指定の根の queries で組む。
  init(queriesRoot: URL?) {
    self.init(
      registry: LanguageRegistry(queriesRoot: queriesRoot),
      make: { makeTextSurface(style: EditorStyle.make(), text: $0) })
  }

  /// 本番の組成。queries は `.app` の同梱物（`BundledResources.root` 直下の資源バンドル）から解く。
  static let shared = EditorSurfaces(queriesRoot: BundledResources.root)
}
