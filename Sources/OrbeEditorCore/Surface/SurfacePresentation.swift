import AppKit

/// 面の表示の構成（→ `TextSurface.setPresentation`）。面を作るときの見え方（字・行高・色・俯瞰の寸法）とは別に、面の
/// 生涯の途中でも置き直せる。置かなければ `code`。
///
/// 行番号の列は左から 番号の列（1 か 2）｜git の印の列｜記号の列 で、その右が本文。
public struct SurfacePresentation: Equatable {
  /// ミニマップを出すか。出さない面は、右列が縦スクロールバーだけになる。差し込み（`SurfaceRows`）を受け付けるのは、
  /// 出さない面だけ。
  public var showsMinimap: Bool
  /// 番号の列の数（1 か 2）。2 なら左の列に「もう一方の番号」（`LineSpan.otherNumber`・差し込んだ行が指す出どころの行の
  /// 番号）、右の列に文書の行の番号を描く。1 なら文書の行の番号だけを描く（差し込んだ行には描かない）。
  public var numberColumns: Int
  /// 番号の列 1 つの最小の幅と、番号の右端から列の右端までの余白（pt。nil なら面を作ったときの見え方の値）。最大の番号が
  /// 収まらなければ列は広がる。
  public var numberWidth: CGFloat?
  public var numberTrailing: CGFloat?
  /// 記号の列の幅（pt。0 なら列を持たない）。行の型の記号（`LineStyle.sign`）をここに描く。
  public var signWidth: CGFloat
  /// git の印の列を持つか。持たない面は列の幅が 0 で、印を描かない。
  public var showsMarks: Bool
  /// 行の型。文書の行の区間（`LineSpan.style`）と差し込んだ行（`InsertedLine.style`）が番号で指す。
  public var lineStyles: [LineStyle]

  public init(
    showsMinimap: Bool = true, numberColumns: Int = 1, numberWidth: CGFloat? = nil,
    numberTrailing: CGFloat? = nil, signWidth: CGFloat = 0, showsMarks: Bool = true,
    lineStyles: [LineStyle] = []
  ) {
    precondition(numberColumns == 1 || numberColumns == 2, "番号の列は 1 か 2")
    self.showsMinimap = showsMinimap
    self.numberColumns = numberColumns
    self.numberWidth = numberWidth
    self.numberTrailing = numberTrailing
    self.signWidth = signWidth
    self.showsMarks = showsMarks
    self.lineStyles = lineStyles
  }

  /// コードの面の構成。
  public static var code: SurfacePresentation { SurfacePresentation() }
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
