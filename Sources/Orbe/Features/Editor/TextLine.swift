import AppKit

/// 1 行の文字列（CoreText の行と寸法）。行の view が中身の変わったときだけ組み、描くたびに組み直さない。色は描くときに
/// 文脈の塗りから当てる。
struct TextLine {
  let line: CTLine
  let font: NSFont
  /// 幅に収まらないときに省く側。
  let truncation: CTLineTruncationType
  let width: CGFloat
  /// 箱の上端から基線まで。
  let ascent: CGFloat
  /// 行の箱の高さ。縦の中央に置くときの箱。
  let height: CGFloat

  /// 字体の割り当て。ユーザー由来の名前（ファイル名・ディレクトリ）は chrome と同じく端末系グリフと絵文字に字体を充て、
  /// コードのプレビューと記号は基底の字体だけで組む（SwiftUI の Text で描いていたときと同じ）。
  enum Glyphs {
    case plain
    case chrome(emoji: NSFont?)
  }

  init(
    _ text: String, _ font: NSFont, glyphs: Glyphs = .plain,
    truncating truncation: CTLineTruncationType = .end
  ) {
    let attributed =
      switch glyphs {
      case .plain:
        NSAttributedString(string: text, attributes: Self.drawing.merging([.font: font]) { $1 })
      case .chrome(let emoji):
        TitleGlyphs.nsAttributed(text, base: font, emoji: emoji, attributes: Self.drawing)
      }
    line = CTLineCreateWithAttributedString(attributed)
    self.font = font
    self.truncation = truncation
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    // 行の箱は TextKit（SwiftUI の Text）と同じ丸め——基線は ascent を丸めた位置、高さはそこへ descent の切り上げを足す。
    // 字の位置が SwiftUI で描いていた他の面の字と半画素ずれない。
    self.ascent = ascent.rounded()
    height = self.ascent + descent.rounded(.up) + leading
  }

  private static let drawing: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
  ]

  /// 字体ごとの省略記号の行（初めて省くときに作る）。
  @MainActor private static var ellipses: [NSFont: CTLine] = [:]

  @MainActor private static func ellipsis(_ font: NSFont) -> CTLine {
    if let line = ellipses[font] { return line }
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: "…", attributes: drawing.merging([.font: font]) { $1 }))
    ellipses[font] = line
    return line
  }

  /// 字体を読み込み、1 度ずつ字組みしておく（省略記号の行もここで作る）。最初の行を描く更新に初回の費用を重ねない。
  @MainActor static func prepare(_ fonts: [NSFont]) {
    for font in fonts {
      _ = TextLine("Ag", font)
      _ = ellipsis(font)
    }
  }

  static func ellipsisWidth(_ font: NSFont) -> CGFloat {
    TextLine("…", font).width
  }

  static func width(of line: CTLine) -> CGFloat {
    CTLineGetTypographicBounds(line, nil, nil, nil)
  }

  /// 幅 `width` に収めた行（溢れは `truncation` の側を省略記号で省く。何も入らなければ nil）。
  @MainActor func fitted(_ width: CGFloat) -> CTLine? {
    guard width > 0 else { return nil }
    guard self.width > width else { return line }
    return CTLineCreateTruncatedLine(line, Double(width), truncation, Self.ellipsis(font))
  }

  /// 幅 `width` に収めて描く。
  @MainActor func draw(
    at x: CGFloat, top: CGFloat, width: CGFloat, _ color: CGColor, _ context: CGContext
  ) {
    if let fitted = fitted(width) {
      draw(fitted, at: x, top: top, color, context)
    }
  }

  /// 省かずに描く。
  func draw(at x: CGFloat, top: CGFloat, _ color: CGColor, _ context: CGContext) {
    draw(line, at: x, top: top, color, context)
  }

  /// この文字列の行（か、それを省いた行）を、上端 `top` の箱に描く。
  func draw(_ line: CTLine, at x: CGFloat, top: CGFloat, _ color: CGColor, _ context: CGContext) {
    context.saveGState()
    context.setFillColor(color)
    // 反転した view の座標（y が下向き）で字を正立させる。
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: x, y: top + ascent)
    CTLineDraw(line, context)
    context.restoreGState()
  }
}
