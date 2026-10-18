import AppKit

/// 行の列（`RowListView`）の行の view の基底。行の番号と選択（地は selectionFill。焦点の有無で色を変えない）とポインタの
/// 位置を持ち、VoiceOver には行（AX の row）として何行目か・選択を渡す。中身は派生が `drawContent` で描き、中身の文字列（AX の
/// ラベル）も派生が渡す。押下は列が受ける（行は素通し）——行の中に押せる部品を置く派生は、その位置を `control(at:)` で答える。
class ListRowView: NSView {
  /// 描いている行の番号（列が枠を割り当てる）。
  var row: Int? {
    didSet { setAccessibilityIndex(row ?? 0) }
  }

  var isSelected = false {
    didSet {
      guard isSelected != oldValue else { return }
      needsDisplay = true
      setAccessibilitySelected(isSelected)
    }
  }

  /// ポインタの位置（行の座標。ポインタがこの行に無ければ nil）。変われば `pointerDidChange` を呼ぶ。
  var pointer: NSPoint? {
    didSet { if pointer != oldValue { pointerDidChange(from: oldValue) } }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    // 描くのは自分の枠の中だけ。枠の外へ描ける（既定）と、列を送るたびに見える範囲が変わったとして見えている行を
    // 全部描き直す。
    clipsToBounds = true
    setAccessibilityElement(true)
    setAccessibilityRole(.row)
  }

  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let colors = RowColors.of(effectiveAppearance)
    if isSelected {
      context.setFillColor(colors.selection)
      context.fill(bounds)
    }
    drawContent(colors, in: context)
  }

  /// 中身を描く（選択の地の上に）。
  func drawContent(_ colors: RowColors, in context: CGContext) {}

  /// ポインタが動いた・入った・出た（hover を描く派生が描き直しを決める）。
  func pointerDidChange(from old: NSPoint?) {}

  /// 行の座標 `point` にある押せる部品（無ければ nil。押せない姿の部品も返す——押して何もしないかは源が決める）。
  func control(at point: NSPoint) -> ListRowControl? { nil }

  /// 行の座標 `point` にある部品の説明（ツールチップ）。
  func help(at point: NSPoint) -> String? { nil }

  // MARK: - 描画の小道具

  /// 装置の画素へ揃える（SwiftUI が view の枠を揃えるのと同じ。字と地が半画素ずれない）。
  final func snap(
    _ value: CGFloat, _ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero
  ) -> CGFloat {
    let scale = window?.backingScaleFactor ?? 2
    return (value * scale).rounded(rule) / scale
  }

  /// 行の縦の中央に置いたときの上端。
  final func top(_ text: TextLine) -> CGFloat {
    snap((bounds.height - text.height) / 2)
  }

  /// 角丸の塗り。
  final func fill(_ rect: NSRect, radius: CGFloat, _ color: CGColor, in context: CGContext) {
    context.setFillColor(color)
    context.addPath(
      CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
  }

  /// シェブロン（`EditorGlyphs.chevron` を `size` 角に。開いていると 90° 回す）を、左端 `x`・行の縦の中央に描く。
  final func drawChevron(
    at x: CGFloat, size: CGFloat, open: Bool, _ color: CGColor, in context: CGContext
  ) {
    let chevron = Self.chevron(size: size)
    context.saveGState()
    context.translateBy(x: x + size / 2, y: bounds.height / 2)
    if open { context.rotate(by: .pi / 2) }
    context.translateBy(x: -size / 2, y: -size / 2)
    context.setStrokeColor(color)
    context.setLineWidth(chevron.lineWidth)
    context.addPath(chevron.path)
    context.strokePath()
    context.restoreGState()
  }

  /// 種別チップ（既定 14。角丸の地＋中央の字。`FileChipView` と同じ規則を AppKit で描く）を、左端 `x`・行の縦の中央に描く。
  final func drawChip(
    _ glyph: TextLine, _ tint: ChipTint, at x: CGFloat, size: CGFloat = Theme.Layout.editorChip,
    radius: CGFloat = Theme.Radius.xs, _ colors: RowColors, in context: CGContext
  ) {
    let rect = NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
    let chip = colors.chip(tint)
    fill(rect, radius: radius, chip.ground, in: context)
    glyph.draw(
      at: snap(rect.midX - glyph.width / 2), top: snap(rect.midY - glyph.height / 2), chip.text,
      context)
  }

  /// シェブロンの線と線の幅（寸法ごとに 1 度だけ作る）。
  private static var chevrons: [CGFloat: (path: CGPath, lineWidth: CGFloat)] = [:]

  static func chevron(size: CGFloat) -> (path: CGPath, lineWidth: CGFloat) {
    if let chevron = chevrons[size] { return chevron }
    let glyph = EditorGlyphs.chevron
    let k = size / glyph.viewBox
    let path = CGMutablePath()
    for part in glyph.parts(k) { path.addPath(part.path.cgPath) }
    let chevron = (path: path as CGPath, lineWidth: glyph.stroke * k)
    chevrons[size] = chevron
    return chevron
  }
}

/// 行の中の押せる部品——源へ渡す番号と、行の座標の枠。
struct ListRowControl: Equatable {
  let id: Int
  let frame: NSRect
}
