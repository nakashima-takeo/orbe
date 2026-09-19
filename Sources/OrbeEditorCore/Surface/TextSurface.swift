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
  func substring(in range: NSRange) -> String

  /// `ranges` の既存の色を外し、`spans` を置く。描画属性としてのみ持ち、本文と undo を汚さない。
  func applyHighlights(_ spans: [HighlightSpan], in ranges: IndexSet)

  /// 今見えている本文の区間（viewport のレイアウト後に更新される。prefetch の帯を含み「見えている」より広い——
  /// 色付けの塗り残しの判定用。見えている範囲そのものは `viewport`）。
  var visibleRange: NSRange { get }

  /// 見えている範囲を本文の言葉で（面の pt は出ない）。
  var viewport: TextViewport { get }

  /// そのオフセットの行を可視範囲の中央へスクロールする（先頭・末尾では端で止まる）。選択は動かさない。
  func scrollToCenter(_ offset: Int)

  /// その区間が見えるところまで最小限スクロールする（縦に見えていれば縦は動かず、横に隠れていれば横だけ寄る）。
  /// 選択は動かさない。
  func scrollToVisible(_ range: NSRange)

  /// 選択（UTF-16）。置いても見せない——見せるのは `scrollToCenter`。
  var selectedRange: NSRange { get set }

  /// ファイル内検索の一致の地。本文と undo に載らない描画で、次に置き直すか空を置くまで残る。`ranges` は
  /// 昇順・重ならないこと（面は二分探索で可視ぶんだけ描く）。
  func setSearchHighlights(_ ranges: [NSRange])

  /// インデントの単位（1 段のスペース数）。文書が本文から検出して押し、面はタブの表示幅と装備の段に写す。
  func setIndentUnit(_ unit: Int)

  /// undo の履歴にここで区切りを置く。続けて打った文字はまとめて戻るが、区切りをまたいでは戻らない
  /// （保存が呼ぶ——⌘Z が保存前の打鍵まで一緒に戻さないため）。
  func markUndoBoundary()

  /// 本文を丸ごと置き換える編集。通常の編集と同じく undo に載り、`didChange`（範囲 = 全体）を呼び出しから
  /// 戻るまでに同期で 1 回通す（外部で書き換えられたファイルの差し替えが呼ぶ——行索引・構文木・ハンクが
  /// 打鍵と同じ経路で追従する）。変換中の IME セッションは置き換える前に畳む（その取り消しの `didChange`
  /// が 1 回先に通る）。置き換え後の選択は解け、キャレットは同じオフセット（本文が短ければ末尾）。
  func replaceAll(with text: String)

  /// 行の印（git ガター）。文書がハンクから作って押す（UTF-16 オフセット）。面は描くだけで規則を持たない。
  func setLineMarks(_ spans: LineMarkSpans)

  /// 本文の URL が ⌘クリックされた。行き先（外部ブラウザ等）は面を組む側が決める。
  var onOpenLink: ((URL) -> Void)? { get set }

  /// 面の地。面はこの色で自分の矩形の地を敷く（透過の veil を二重にしないため、載せる側と分担する）。
  /// 載せる側の義務: 自分の地と同じ色（透過設定を反映した veil）を渡す／面の矩形には自分の地を描かない／
  /// 面の矩形が動いたら自分の地を描き直す／設定が変われば渡し直す。
  func setGround(_ color: NSColor)

  var delegate: TextSurfaceDelegate? { get set }
}

@MainActor
public protocol TextSurfaceDelegate: AnyObject {
  func surface(_ surface: any TextSurface, didChange edit: TextEdit)
  func surface(_ surface: any TextSurface, focusDidChange focused: Bool)
  func surfaceDidLayoutViewport(_ surface: any TextSurface)
  /// `viewport` が変わった（スクロール・窓の高さ）。
  func surfaceDidScroll(_ surface: any TextSurface)
  func surfaceDidChangeSelection(_ surface: any TextSurface)
}

/// 見えている範囲を本文の言葉で表したもの。`firstVisible` は先頭に見えている行の行頭オフセット、
/// `hiddenFraction` はその行が上へ隠れている割合（0…1）、`visibleLines` は可視矩形に入る行数（小数）。
/// エンジンの推定の文書高に依らず、実際に layout された行の矩形から出る。
public struct TextViewport: Equatable, Sendable {
  public var firstVisible: Int
  public var hiddenFraction: CGFloat
  public var visibleLines: CGFloat

  public init(firstVisible: Int, hiddenFraction: CGFloat, visibleLines: CGFloat) {
    self.firstVisible = firstVisible
    self.hiddenFraction = hiddenFraction
    self.visibleLines = visibleLines
  }

  public static let empty = TextViewport(firstVisible: 0, hiddenFraction: 0, visibleLines: 0)
}

/// 面の見え方。色は名前付き（dynamic）の NSColor を渡し、外観は描画時に解く。装備の寸法と色もここで渡し、
/// エンジンは値を持たない。
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
  public var marks: Marks
  public var decorations: Decorations

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

  /// 本文に重なる装備（インデント線・空白の丸点・URL の下線）の見え方。
  public struct Decorations {
    public var indentGuideColor: NSColor
    public var indentGuideWidth: CGFloat
    public var whitespaceColor: NSColor
    public var whitespaceDiameter: CGFloat
    public var linkUnderlineThickness: CGFloat
    /// ベースラインから下線の上端まで。
    public var linkUnderlineOffset: CGFloat
    /// ファイル内検索の一致の地（α 込み）と角。
    public var searchMatchColor: NSColor
    public var searchMatchRadius: CGFloat

    public init(
      indentGuideColor: NSColor, indentGuideWidth: CGFloat, whitespaceColor: NSColor,
      whitespaceDiameter: CGFloat, linkUnderlineThickness: CGFloat, linkUnderlineOffset: CGFloat,
      searchMatchColor: NSColor, searchMatchRadius: CGFloat
    ) {
      self.indentGuideColor = indentGuideColor
      self.indentGuideWidth = indentGuideWidth
      self.whitespaceColor = whitespaceColor
      self.whitespaceDiameter = whitespaceDiameter
      self.linkUnderlineThickness = linkUnderlineThickness
      self.linkUnderlineOffset = linkUnderlineOffset
      self.searchMatchColor = searchMatchColor
      self.searchMatchRadius = searchMatchRadius
    }
  }

  public init(
    font: NSFont, lineHeight: CGFloat, topInset: CGFloat, textColor: NSColor, caretColor: NSColor,
    caretSize: CGSize, gutterFont: NSFont, gutterTextColor: NSColor, gutterWidth: CGFloat,
    gutterTrailingInset: CGFloat, roleColors: [SyntaxRole: NSColor], marks: Marks,
    decorations: Decorations
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
    self.marks = marks
    self.decorations = decorations
  }
}
