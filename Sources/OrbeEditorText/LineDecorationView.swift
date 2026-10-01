import AppKit
import OrbeEditorCore
import STTextView

/// 本文の overlay——インデント線・空白の丸点・URL の下線を、テキスト view の `contentView` の下に描く
/// （上流の本文・キャレット・選択の view は地を塗らないので、下に置けばそれらの下に出る。選択の地は装備を
/// 覆う）。何を描くかは描く行の文字列から Core の純関数で毎回導き、状態はインデント単位だけ。当たりを持たず、
/// 寸法は viewport で、位置は面がスクロールと layout のたびに置き直す。bounds は text container 基準なので、
/// geometry の座標をそのまま描く。
final class LineDecorationView: NSView {
  private weak var textView: STTextView?
  private let style: TextSurfaceStyle.Decorations
  private let textColor: NSColor
  var indentUnit = Indentation.fallback.unit {
    didSet { needsDisplay = true }
  }

  init(textView: STTextView, style: TextSurfaceStyle.Decorations, textColor: NSColor) {
    self.textView = textView
    self.style = style
    self.textColor = textColor
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let textView else { return }
    let geometry = VisibleLines(textView: textView)
    let lines = geometry.lines(in: bounds)
    guard !lines.isEmpty else { return }
    let cell = textView.font.cellWidth
    for (line, level) in zip(lines, indentLevels(lines, geometry: geometry)) {
      drawIndentGuides(line, level: level, geometry: geometry, cell: cell)
      drawWhitespace(line, geometry: geometry)
      drawLinks(line, geometry: geometry)
    }
  }

  /// 見えている段落（続いた並び）のインデント線の段の数。空白だけの段落の規則は `IndentGuides.levels` で、並びの外の
  /// 非空行は端の段落が空白だけのときだけ探す。
  private func indentLevels(_ lines: [VisibleLine], geometry: VisibleLines) -> [Int] {
    let level = { (text: String) in
      IndentGuides.boundaries(of: text.utf16, unit: self.indentUnit).count
    }
    let own = lines.map { IndentGuides.isBlank($0.text.utf16) ? nil : level($0.text) }
    let outside = { (line: VisibleLine?, forward: Bool) -> Int? in
      guard let line, IndentGuides.isBlank(line.text.utf16) else { return nil }
      return geometry.neighbourNonBlank(of: line, forward: forward).map(level)
    }
    return IndentGuides.levels(
      own, above: outside(lines.first, false), below: outside(lines.last, true))
  }

  /// 段 k の線は行頭から k 単位ぶんの空白の直後の文字の左端に立つ。空白だけの行は隣の非空行の浅い方の段まで、
  /// 桁幅から求めた位置に立つ。
  private func drawIndentGuides(
    _ line: VisibleLine, level: Int, geometry: VisibleLines, cell: CGFloat
  ) {
    let boundaries = IndentGuides.boundaries(of: line.text.utf16, unit: indentUnit)
    guard level > 0, let row = line.rows.first else { return }
    style.indentGuideColor.setFill()
    for k in 0..<level {
      let x =
        k < boundaries.count
        ? geometry.x(of: boundaries[k], in: row) : CGFloat((k + 1) * indentUnit) * cell
      backingAlignedRect(
        NSRect(
          x: x, y: line.frame.minY, width: style.indentGuideWidth,
          height: line.bodyMaxY - line.frame.minY),
        options: .alignAllEdgesNearest
      ).fill()
    }
  }

  private func drawWhitespace(_ line: VisibleLine, geometry: VisibleLines) {
    let runs = WhitespaceRuns.runs(in: line.text.utf16)
    guard !runs.isEmpty else { return }
    style.whitespaceColor.setFill()
    let diameter = style.whitespaceDiameter
    for run in runs {
      for index in run {
        guard let row = geometry.row(containing: index, in: line) else { continue }
        let center = CGPoint(
          x: (geometry.x(of: index, in: row) + geometry.x(of: index + 1, in: row)) / 2,
          y: row.frame.midY)
        NSBezierPath(
          ovalIn: NSRect(
            x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter,
            height: diameter)
        ).fill()
      }
    }
  }

  /// 下線は文字と同色（区間の先頭の描画色）で、ベースラインの下に置く。
  private func drawLinks(_ line: VisibleLine, geometry: VisibleLines) {
    for link in geometry.links(in: line) {
      (link.color ?? textColor).setFill()
      backingAlignedRect(
        NSRect(
          x: link.frame.minX, y: link.baseline + style.linkUnderlineOffset,
          width: link.frame.width, height: style.linkUnderlineThickness),
        options: .alignAllEdgesNearest
      ).fill()
    }
  }
}
