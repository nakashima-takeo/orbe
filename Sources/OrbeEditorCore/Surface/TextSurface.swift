import AppKit

/// 文字を描き編集を受ける面の、エンジン非依存の契約。本文・undo・選択・スクロールの正は常に面にある。
/// 文書は面の delegate として編集を受け、色は役割付き区間として面へ渡す（面は役割→色だけを知る）。
@MainActor
public protocol TextSurface: AnyObject {
  /// 器へ載せる view（スクロールを含む全体）。
  var view: NSView { get }
  /// first responder にする view。
  var responder: NSView { get }

  var text: String { get }
  /// UTF-16 の長さ。
  var length: Int { get }
  func substring(in range: NSRange) -> String

  /// 見え方。setter でフォント・行高・文字色・キャレット・ガター・役割→色を面へ適用する。
  /// 既に塗ってある色は塗り直さない（再発行できるのは構文層だけ）。
  var style: TextSurfaceStyle { get set }

  /// `ranges` の既存の色を外し、`spans` を置く。描画属性としてのみ持ち、本文と undo を汚さない。
  func applyHighlights(_ spans: [HighlightSpan], in ranges: IndexSet)

  /// 今見えている本文の区間（viewport のレイアウト後に更新される）。
  var visibleRange: NSRange { get }

  /// undo の履歴にここで区切りを置く。続けて打った文字はまとめて戻るが、区切りをまたいでは戻らない
  /// （保存が呼ぶ——⌘Z が保存前の打鍵まで一緒に戻さないため）。
  func markUndoBoundary()

  var delegate: TextSurfaceDelegate? { get set }
}

@MainActor
public protocol TextSurfaceDelegate: AnyObject {
  func surface(_ surface: any TextSurface, didChange edit: TextEdit)
  func surfaceDidChangeSelection(_ surface: any TextSurface)
  func surface(_ surface: any TextSurface, focusDidChange focused: Bool)
  func surfaceDidLayoutViewport(_ surface: any TextSurface)
}

/// 面の見え方。色は名前付き（dynamic）の NSColor を渡し、外観は描画時に解く。
public struct TextSurfaceStyle {
  public var font: NSFont
  /// 行の高さ（pt）。フォントの自然な行高に依らず固定する。
  public var lineHeight: CGFloat
  /// 本文の上端の余白。
  public var topInset: CGFloat
  /// 役割を持たない文字の色。
  public var textColor: NSColor
  public var caretColor: NSColor
  public var caretSize: CGSize
  public var gutterFont: NSFont
  public var gutterTextColor: NSColor
  /// 行番号ガターの幅（行数がこの幅に収まる限り広がらない）。
  public var gutterWidth: CGFloat
  /// 行番号の右端と本文の間。
  public var gutterTrailingInset: CGFloat
  public var roleColors: [SyntaxRole: NSColor]

  public init(
    font: NSFont, lineHeight: CGFloat, topInset: CGFloat, textColor: NSColor, caretColor: NSColor,
    caretSize: CGSize, gutterFont: NSFont, gutterTextColor: NSColor, gutterWidth: CGFloat,
    gutterTrailingInset: CGFloat, roleColors: [SyntaxRole: NSColor]
  ) {
    self.font = font
    self.lineHeight = lineHeight
    self.topInset = topInset
    self.textColor = textColor
    self.caretColor = caretColor
    self.caretSize = caretSize
    self.gutterFont = gutterFont
    self.gutterTextColor = gutterTextColor
    self.gutterWidth = gutterWidth
    self.gutterTrailingInset = gutterTrailingInset
    self.roleColors = roleColors
  }
}
