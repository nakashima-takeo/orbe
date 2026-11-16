import AppKit

/// 列の行の中で描く印（`EditorGlyphs` を CGPath にしたもの。寸法ごとに 1 度だけ作る）。
enum RowGlyphShape: Hashable {
  case chevron, chevronOpen, openFile, discard, plus, minus, branch
  case check, viewAsTree, viewAsList

  private var glyph: EditorGlyphs.Glyph {
    switch self {
    case .chevron, .chevronOpen: EditorGlyphs.chevron
    case .openFile: EditorGlyphs.openFile
    case .discard: EditorGlyphs.discard
    case .plus: EditorGlyphs.plus
    case .minus: EditorGlyphs.minus
    case .branch: EditorGlyphs.branch
    case .check: EditorGlyphs.checkboxCheck
    case .viewAsTree: EditorGlyphs.viewAsTree
    case .viewAsList: EditorGlyphs.viewAsList
    }
  }

  struct Path {
    let path: CGPath
    let lineWidth: CGFloat
    let fills: Bool
  }

  @MainActor private static var cache: [Self: [CGFloat: Path]] = [:]

  @MainActor func path(size: CGFloat) -> Path {
    if let path = Self.cache[self]?[size] { return path }
    let glyph = self.glyph
    let k = size / glyph.viewBox
    let path = CGMutablePath()
    for part in glyph.parts(k) { path.addPath(part.path.cgPath) }
    var shaped: CGPath = path
    if self == .chevronOpen {
      var turn = CGAffineTransform(translationX: size / 2, y: size / 2).rotated(by: .pi / 2)
        .translatedBy(x: -size / 2, y: -size / 2)
      shaped = path.copy(using: &turn) ?? path
    }
    let made = Path(path: shaped, lineWidth: glyph.stroke * k, fills: glyph.fills)
    Self.cache[self, default: [:]][size] = made
    return made
  }

  /// `rect`（正方形）に `color` で描く。
  @MainActor func draw(in rect: NSRect, _ color: CGColor, in context: CGContext) {
    let path = path(size: rect.width)
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.minY)
    if path.fills {
      context.setFillColor(color)
      context.addPath(path.path)
      context.fillPath()
    } else {
      context.setStrokeColor(color)
      context.setLineWidth(path.lineWidth)
      context.addPath(path.path)
      context.strokePath()
    }
    context.restoreGState()
  }
}
