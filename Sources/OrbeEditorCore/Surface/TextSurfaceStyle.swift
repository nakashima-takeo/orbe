import AppKit

/// 面の見え方。色は名前付き（dynamic）の NSColor を渡し、外観は描画時に解く。装備と俯瞰の寸法と色もここで渡し、
/// エンジンは値を持たない。
public struct TextSurfaceStyle {
  public var font: NSFont
  /// 行の高さ（pt）。フォントの自然な行高に依らず固定する。
  public var lineHeight: CGFloat
  /// 本文の上端の余白。
  public var topInset: CGFloat
  /// 役割を持たない文字の色。
  public var textColor: NSColor
  /// 本文の地の不透明な色。面は地を描かず下を透かす。色付きで書き出す（コピーの HTML）ときの地に使う。
  public var backgroundColor: NSColor
  public var caretColor: NSColor
  public var caretSize: CGSize
  /// 選択の地の色。焦点が無い面では `inactiveSelectionColor`。
  public var selectionColor: NSColor
  public var inactiveSelectionColor: NSColor
  public var gutterFont: NSFont
  public var gutterTextColor: NSColor
  /// 行番号の数字の部分の幅（右の印の列を除く）。最大の行番号と右の余白（`gutterTrailingInset`）がこの幅に収まる
  /// 限り、列は広がらない。
  public var gutterWidth: CGFloat
  /// 行番号の右端と本文の間。
  public var gutterTrailingInset: CGFloat
  public var roleColors: [SyntaxRole: NSColor]
  public var marks: Marks
  public var decorations: Decorations
  public var highlights: Highlights
  public var overview: Overview

  /// git ガター（行番号の右の列）の見え方。色は α 込み。
  public struct Marks {
    public var gutterWidth: CGFloat
    public var barWidth: CGFloat
    /// 列の左端からバーの左端まで。
    public var barInset: CGFloat
    public var barRadius: CGFloat
    /// 削除の三角（右向き）の一辺。
    public var triangleSize: CGFloat
    public var added: NSColor
    public var modified: NSColor
    public var removed: NSColor

    public init(
      gutterWidth: CGFloat, barWidth: CGFloat, barInset: CGFloat, barRadius: CGFloat,
      triangleSize: CGFloat, added: NSColor, modified: NSColor, removed: NSColor
    ) {
      self.gutterWidth = gutterWidth
      self.barWidth = barWidth
      self.barInset = barInset
      self.barRadius = barRadius
      self.triangleSize = triangleSize
      self.added = added
      self.modified = modified
      self.removed = removed
    }
  }

  /// 本文に重なる装備（空白の丸点・URL の下線）の見え方。
  public struct Decorations {
    public var whitespaceColor: NSColor
    public var whitespaceDiameter: CGFloat
    public var linkUnderlineThickness: CGFloat
    /// ベースラインから下線の上端まで。
    public var linkUnderlineOffset: CGFloat

    public init(
      whitespaceColor: NSColor, whitespaceDiameter: CGFloat, linkUnderlineThickness: CGFloat,
      linkUnderlineOffset: CGFloat
    ) {
      self.whitespaceColor = whitespaceColor
      self.whitespaceDiameter = whitespaceDiameter
      self.linkUnderlineThickness = linkUnderlineThickness
      self.linkUnderlineOffset = linkUnderlineOffset
    }
  }

  /// 強調の地の色（α 込み。行の高さいっぱい・角なしで塗る）。選択文字列の出現は面に焦点が無いときだけ
  /// `selectionOccurrenceInactive`。現在の一致の行全体は `currentFindLine`。
  public struct Highlights {
    public var findMatch: NSColor
    public var currentFindMatch: NSColor
    public var currentFindLine: NSColor
    public var selectionOccurrence: NSColor
    public var selectionOccurrenceInactive: NSColor
    public var wordOccurrence: NSColor

    public init(
      findMatch: NSColor, currentFindMatch: NSColor, currentFindLine: NSColor,
      selectionOccurrence: NSColor, selectionOccurrenceInactive: NSColor, wordOccurrence: NSColor
    ) {
      self.findMatch = findMatch
      self.currentFindMatch = currentFindMatch
      self.currentFindLine = currentFindLine
      self.selectionOccurrence = selectionOccurrence
      self.selectionOccurrenceInactive = selectionOccurrenceInactive
      self.wordOccurrence = wordOccurrence
    }
  }

  /// 俯瞰の見え方——寸法・色（α 込み）・帯とつまみの現れる・消える時間。字の明るさの係数と全体の不透明度は VS Code の
  /// 規則で、見え方ではない（→ `MinimapCharSheet`）。
  public struct Overview {
    public var minimap: Minimap
    public var scrollbar: Scrollbar
    /// 先頭の行が上へ隠れている間の本文の上端の影と、本文が右に続くときのミニマップの左端の影の色。
    public var topShadow: NSColor
    public var minimapShadow: NSColor
    /// 帯とつまみが現れる時間・つまみが消える時間・スクロールが止まってからつまみが消え始めるまで（秒）。
    public var fadeIn: Double
    public var fadeOut: Double
    public var hideDelay: Double

    public init(
      minimap: Minimap, scrollbar: Scrollbar, topShadow: NSColor, minimapShadow: NSColor,
      fadeIn: Double, fadeOut: Double, hideDelay: Double
    ) {
      self.minimap = minimap
      self.scrollbar = scrollbar
      self.topShadow = topShadow
      self.minimapShadow = minimapShadow
      self.fadeIn = fadeIn
      self.fadeOut = fadeOut
      self.hideDelay = hideDelay
    }
  }

  /// ミニマップ——幅の上限と、帯（普段・帯の上・ドラッグ中）・選択・検索の一致・語の出現・git の印の色。
  public struct Minimap {
    public var maxWidth: CGFloat
    public var slider: NSColor
    public var sliderHover: NSColor
    public var sliderActive: NSColor
    public var selection: NSColor
    public var findMatch: NSColor
    public var wordOccurrence: NSColor
    public var added: NSColor
    public var modified: NSColor
    public var removed: NSColor

    public init(
      maxWidth: CGFloat, slider: NSColor, sliderHover: NSColor, sliderActive: NSColor,
      selection: NSColor, findMatch: NSColor, wordOccurrence: NSColor, added: NSColor,
      modified: NSColor, removed: NSColor
    ) {
      self.maxWidth = maxWidth
      self.slider = slider
      self.sliderHover = sliderHover
      self.sliderActive = sliderActive
      self.selection = selection
      self.findMatch = findMatch
      self.wordOccurrence = wordOccurrence
      self.added = added
      self.modified = modified
      self.removed = removed
    }
  }

  /// スクロールバー——縦の幅・横の高さと、つまみ（普段・つまみの上・ドラッグ中）・印（縁・検索の一致・語の出現・git・
  /// キャレット）の色。
  public struct Scrollbar {
    public var width: CGFloat
    public var horizontalHeight: CGFloat
    public var slider: NSColor
    public var sliderHover: NSColor
    public var sliderActive: NSColor
    public var border: NSColor
    public var findMatch: NSColor
    public var wordOccurrence: NSColor
    public var added: NSColor
    public var modified: NSColor
    public var removed: NSColor
    public var caret: NSColor

    public init(
      width: CGFloat, horizontalHeight: CGFloat, slider: NSColor, sliderHover: NSColor,
      sliderActive: NSColor, border: NSColor, findMatch: NSColor, wordOccurrence: NSColor,
      added: NSColor, modified: NSColor, removed: NSColor, caret: NSColor
    ) {
      self.width = width
      self.horizontalHeight = horizontalHeight
      self.slider = slider
      self.sliderHover = sliderHover
      self.sliderActive = sliderActive
      self.border = border
      self.findMatch = findMatch
      self.wordOccurrence = wordOccurrence
      self.added = added
      self.modified = modified
      self.removed = removed
      self.caret = caret
    }
  }

  public init(
    font: NSFont, lineHeight: CGFloat, topInset: CGFloat, textColor: NSColor,
    backgroundColor: NSColor, caretColor: NSColor, caretSize: CGSize, selectionColor: NSColor,
    inactiveSelectionColor: NSColor, gutterFont: NSFont, gutterTextColor: NSColor,
    gutterWidth: CGFloat, gutterTrailingInset: CGFloat,
    roleColors: [SyntaxRole: NSColor], marks: Marks, decorations: Decorations,
    highlights: Highlights, overview: Overview
  ) {
    self.font = font
    self.lineHeight = lineHeight
    self.topInset = topInset
    self.textColor = textColor
    self.backgroundColor = backgroundColor
    self.caretColor = caretColor
    self.caretSize = caretSize
    self.selectionColor = selectionColor
    self.inactiveSelectionColor = inactiveSelectionColor
    self.gutterFont = gutterFont
    self.gutterTextColor = gutterTextColor
    self.gutterWidth = gutterWidth
    self.gutterTrailingInset = gutterTrailingInset
    self.roleColors = roleColors
    self.marks = marks
    self.decorations = decorations
    self.highlights = highlights
    self.overview = overview
  }
}
