import AppKit

/// 面の表示の構成（→ `TextSurface.setPresentation`）。面を作るときの見え方（字・行高・色・俯瞰の寸法）とは別に、面の
/// 生涯の途中でも置き直せる。置かなければ `code`。
///
/// 行番号の列は左から 頭の列｜番号の列（1 か 2）｜git の印の列｜記号の列 で、その右が本文。頭の列は、行の頭の印
/// （`leadingMark`）を持つ構成だけが持つ。
public struct SurfacePresentation: Equatable {
  /// ミニマップを出すか。出さない面は、右列が縦スクロールバーだけになる。差し込み（`SurfaceRows`）を受け付けるのは、
  /// 出さない面だけ。
  public var showsMinimap: Bool
  /// 番号の列の数（1 か 2）。2 なら左の列に「もう一方の番号」（`LineSpan.otherNumber`・差し込んだ行が指す出どころの行の
  /// 番号）、右の列に文書の行の番号を描く。1 なら文書の行の番号だけを描く（差し込んだ行には描かない）。
  public var numberColumns: Int
  /// 文書の行の番号（自分の番号の列。2 列なら右の列）を描くか。描かない面でも、2 列の左の列の「もう一方の番号」
  /// （`LineSpan.otherNumber`・差し込んだ行が指す出どころの行の番号）は描く。文書の行が存在しない行（diff の版が無い側の
  /// 面の空の行）の面だけが、描かない。
  public var numbersOwnLines: Bool
  /// 番号の列 1 つの最小の幅と、番号の右端から列の右端までの余白（pt。nil なら面を作ったときの見え方の値）。最大の番号が
  /// 収まらなければ列は広がる。
  public var numberWidth: CGFloat?
  public var numberTrailing: CGFloat?
  /// 記号の列の幅（pt。0 なら列を持たない）。行の型の記号（`LineStyle.sign`）をここに描く。
  public var signWidth: CGFloat
  /// git の印の列を持つか。持たない面は列の幅が 0 で、印を描かない（スクロールバーにも描かない）。
  public var showsMarks: Bool
  /// 行の型。文書の行の区間（`LineSpan.style`）と差し込んだ行（`InsertedLine.style`）が番号で指す。
  public var lineStyles: [LineStyle]
  /// 行の上書き。文書の行の区間（`LineSpan.override`）と差し込んだ行（`InsertedLine.override`）と、行の頭の印を引いている
  /// 範囲（`LeadingMark.dragOverride`）が番号で指す。
  public var lineOverrides: [LineOverride]
  /// 行の頭の印の見え方（nil なら頭の列を持たず、印を出さない）。
  public var leadingMark: LeadingMark?
  /// 文書の行を本文の区画の幅で折り返すか。折り返す面は横の範囲を持たない。とても大きい文書は、折り返す構成でも
  /// 折り返さない（→ `TextSurface`）。
  public var wraps: Bool

  public init(
    showsMinimap: Bool = true, numberColumns: Int = 1, numbersOwnLines: Bool = true,
    numberWidth: CGFloat? = nil,
    numberTrailing: CGFloat? = nil, signWidth: CGFloat = 0, showsMarks: Bool = true,
    lineStyles: [LineStyle] = [], lineOverrides: [LineOverride] = [],
    leadingMark: LeadingMark? = nil, wraps: Bool = false
  ) {
    precondition(numberColumns == 1 || numberColumns == 2, "番号の列は 1 か 2")
    self.showsMinimap = showsMinimap
    self.numberColumns = numberColumns
    self.numbersOwnLines = numbersOwnLines
    self.numberWidth = numberWidth
    self.numberTrailing = numberTrailing
    self.signWidth = signWidth
    self.showsMarks = showsMarks
    self.lineStyles = lineStyles
    self.lineOverrides = lineOverrides
    self.leadingMark = leadingMark
    self.wraps = wraps
  }

  /// コードの面の構成（折り返す）。
  public static var code: SurfacePresentation { SurfacePresentation(wraps: true) }
}

/// 行の型——行の見え方。色は名前つき（dynamic）の NSColor を渡し、外観は面が描くときに解く。面は型の意味（追加・削除・
/// 詰め物）を知らない。字は型に依らず構文の色で描く。
public struct LineStyle: Equatable {
  /// 行の地（行番号の列の左端から面の右端——縦スクロールバーの列の下——まで）。
  public var background: NSColor?
  /// 記号の列に描く字と、その色（色が無ければ行番号の色）。
  public var sign: String?
  public var signColor: NSColor?

  public init(background: NSColor? = nil, sign: String? = nil, signColor: NSColor? = nil) {
    self.background = background
    self.sign = sign
    self.signColor = signColor
  }
}

/// 行の上書き——行の型（地と記号）とは別に、行の地と頭の線の色だけを替える（記号は行の型のまま）。色は名前つき
/// （dynamic）の NSColor を渡す。どちらも nil なら、その見え方は行の型と頭の印のまま。
public struct LineOverride: Equatable {
  /// 行の地（行の型の地の代わり）。
  public var background: NSColor?
  /// 頭の線の色（印を出せる行の線の、頭の印の色の代わり）。
  public var markColor: NSColor?

  public init(background: NSColor? = nil, markColor: NSColor? = nil) {
    self.background = background
    self.markColor = markColor
  }
}

/// 行の頭の印——行番号の列の左端に足す頭の列に、印を出せる行（`LineSpan`・`InsertedLine` の `markGroup` を持つ行）の左端の
/// 線をいつも描き、ポインタが乗った行に絵（＋）を出す。絵を押せば、その行を受け手（`SurfaceRows.leadingMarkTarget`）へ
/// 知らせ、押したまま上下へ引けば、押した行と同じ組の行までを範囲にして、離したときに範囲を知らせる。絵は行の上端から行
/// 1 つ分の高さの縦の中央・頭の列の左右の中央に置き、外観と倍率で面が描くので、名前つき（dynamic）の色で描く。絵は
/// 同一性で比べるので、同じ見え方には同じ参照を渡す。
public struct LeadingMark: Equatable {
  /// 頭の列の幅と、線の幅（pt）と色。
  public var width: CGFloat
  public var lineWidth: CGFloat
  public var lineColor: NSColor
  /// 絵の大きさ（pt）と絵。
  public var size: CGSize
  public var image: NSImage
  /// 引いている範囲の行に当てる行の上書き（`SurfacePresentation.lineOverrides` の番号）。
  public var dragOverride: Int?

  public init(
    width: CGFloat, lineWidth: CGFloat, lineColor: NSColor, size: CGSize, image: NSImage,
    dragOverride: Int?
  ) {
    self.width = width
    self.lineWidth = lineWidth
    self.lineColor = lineColor
    self.size = size
    self.image = image
    self.dragOverride = dragOverride
  }
}
