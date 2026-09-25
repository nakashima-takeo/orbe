import AppKit
import OrbeEditorCore
import STTextView

/// 行番号の列が行について問い合わせる先（面が文書へ取り次ぐ）。行は `LineIndex` の行。
@MainActor
protocol LineSource: AnyObject {
  var lineCount: Int { get }
  func line(containing offset: Int) -> Int
  /// 行頭から次の行頭まで（最終行は本文の終わりまで）。
  func range(ofLine line: Int) -> NSRange
}

/// 行番号の列。本文の左に並び（スクロールビューの外）、見えている行の番号だけを描いて、その右の印の列に git の印
/// （`LineMarksView`）を持つ。位置は実際の行片の矩形（`VisibleLines`）から取り、bounds の y は文書（text container）
/// 基準——面が clip の上端に合わせて置き直すので、本文と同じコマで動く。番号は行索引の行の番号で、行頭が行索引の行頭で
/// ない段落（単独の `\r` などで TextKit が割った段落）には描かない。
///
/// 番号を押すとその行を選ぶ（VS Code の既定: 押した行を起点に、ドラッグで行単位に伸ばし、本文の上下の外では自動スクロール
/// で伸び続け、⇧で今の選択の起点から伸ばす。選択の動く側の端はポインタの側）。印の列は押しても何もしない。
final class LineNumbersView: NSView {
  private let textView: SurfaceTextView
  private let style: TextSurfaceStyle
  let marksView: LineMarksView
  weak var source: LineSource?
  /// 押してから離すまでの起点（行の選択が伸びる元の区間）。
  private var anchor: NSRange?
  /// 最後に列から置いた選択と、そのときの起点（選択がそのままなら ⇧クリックはその起点から伸ばす）。
  private var lastSelection: (range: NSRange, anchor: NSRange)?

  init(textView: SurfaceTextView, style: TextSurfaceStyle) {
    self.textView = textView
    self.style = style
    marksView = LineMarksView(textView: textView, style: style.marks)
    super.init(frame: .zero)
    // 上端で半ば隠れた行の番号を、上の余白や骨へはみ出して描かない（本文は clip view が切る）。
    clipsToBounds = true
    addSubview(marksView)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  /// 列の幅——最小の幅か、最大の行番号の桁が右の余白と印の列を残して収まる幅の広い方。
  var fittingWidth: CGFloat {
    let digits = ceil(CTLineGetTypographicBounds(numberLine(source?.lineCount ?? 1), nil, nil, nil))
    return max(style.gutterWidth + style.marks.gutterWidth, digits + trailingInset)
  }

  /// 数字の右端から列の右端まで（右の余白と印の列）。
  private var trailingInset: CGFloat { style.gutterTrailingInset + style.marks.gutterWidth }

  /// clip の縦の範囲（文書の座標）に合わせて置き直す。
  func follow(_ clip: NSRect) {
    setBoundsOrigin(NSPoint(x: 0, y: clip.minY))
    marksView.frame = NSRect(
      x: bounds.width - style.marks.gutterWidth, y: clip.minY, width: style.marks.gutterWidth,
      height: bounds.height)
    marksView.setBoundsOrigin(NSPoint(x: 0, y: clip.minY))
    needsDisplay = true
    marksView.needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let source, let context = NSGraphicsContext.current?.cgContext else { return }
    let geometry = VisibleLines(textView: textView)
    guard geometry.documentLength > 0 else {
      drawEmptyDocument(context)
      return
    }
    for line in geometry.lines(in: CGRect(x: 0, y: bounds.minY, width: 1, height: bounds.height)) {
      let body = line.rows.filter { !$0.isExtra }
      if let first = body.first {
        let frame = body.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        drawNumber(at: line.range.location, row: first.frame, cell: frame, source, context)
      }
      if let extra = line.extraRow {
        drawNumber(
          at: NSMaxRange(line.range), row: extra.frame, cell: extra.frame, source, context)
      }
    }
  }

  /// 行頭 `offset` の行の番号を、行片 `row` の縦の中央に揃えて描く（`cell` は番号が受け持つ段落の矩形）。行索引の
  /// 行頭でなければ描かない。
  private func drawNumber(
    at offset: Int, row: CGRect, cell: CGRect, _ source: LineSource, _ context: CGContext
  ) {
    let line = source.line(containing: offset)
    guard source.range(ofLine: line).location == offset else { return }
    draw(line + 1, centeredOn: row.midY, cell: cell, context)
  }

  /// 空の文書（TextKit は layout fragment を作らない）は、文書の先頭の位置に 1 を描く。
  private func drawEmptyDocument(_ context: CGContext) {
    let layoutManager = textView.textLayoutManager
    var frame: CGRect?
    layoutManager.enumerateTextSegments(
      in: NSTextRange(location: layoutManager.documentRange.location), type: .standard,
      options: []
    ) { _, rect, _, _ in
      frame = rect
      return false
    }
    guard let frame else { return }
    let cell = NSIntegralRectWithOptions(frame, .alignAllEdgesNearest)
    draw(1, centeredOn: cell.midY, cell: cell, context)
  }

  /// 番号を右寄せで描く。縦は字の見た目の中央（ascent と descent の中点）を `centerY` に置く。
  private func draw(_ number: Int, centeredOn centerY: CGFloat, cell: CGRect, _ context: CGContext)
  {
    let line = numberLine(number)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let width = ceil(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    let clip = NSIntegralRectWithOptions(
      CGRect(x: 0, y: cell.minY, width: bounds.width, height: cell.height), .alignAllEdgesNearest)
    context.saveGState()
    context.clip(to: clip)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(
      x: bounds.width - (width + trailingInset), y: centerY + (ascent - descent) / 2)
    CTLineDraw(line, context)
    context.restoreGState()
  }

  private func numberLine(_ number: Int) -> CTLine {
    CTLineCreateWithAttributedString(
      NSAttributedString(
        string: "\(number)",
        attributes: [
          .font: style.gutterFont, .foregroundColor: style.gutterTextColor,
          .paragraphStyle: textView.defaultParagraphStyle,
        ]))
  }

  // MARK: - 行の選択

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard point.x < bounds.width - style.marks.gutterWidth, let source,
      let line = line(atY: point.y, source)
    else { return }
    window?.makeFirstResponder(textView)
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.shift) {
      let selection = textView.textSelection
      if let last = lastSelection, last.range == selection {
        anchor = last.anchor
      } else {
        let fixed =
          textView.caretLocation == selection.location ? NSMaxRange(selection) : selection.location
        anchor = NSRange(location: fixed, length: 0)
      }
    } else {
      anchor = source.range(ofLine: line)
    }
    extend(to: line, source)
  }

  /// 本文の上下の外へ出たら、ポインタが止まっていても自動スクロールで伸び続ける（VS Code の
  /// `TopBottomDragScrolling`）。中へ戻れば止めて、ポインタの行まで伸ばす。
  override func mouseDragged(with event: NSEvent) {
    guard anchor != nil, let source else { return }
    let y = convert(event.locationInWindow, from: nil).y
    if y < bounds.minY || y > bounds.maxY {
      let running = edge != nil
      edge = Edge(
        above: y < bounds.minY, distance: y < bounds.minY ? bounds.minY - y : y - bounds.maxY)
      guard !running else { return }
      lastTick = now()
      autoscroll.generation += 1
      scheduleTick(autoscroll.generation)
      return
    }
    edge = nil
    guard let line = line(atY: y, source) else { return }
    extend(to: line, source)
  }

  override func mouseUp(with event: NSEvent) {
    anchor = nil
    edge = nil
  }

  // MARK: - 自動スクロール

  /// ポインタが本文のどちら側に、どれだけ外れているか。
  private struct Edge {
    let above: Bool
    let distance: CGFloat
  }

  private var edge: Edge? {
    didSet { if edge == nil { autoscroll.generation += 1 } }
  }
  private var lastTick: TimeInterval = 0
  /// 自動スクロールの時計と、次のコマの予約（テストが差し替える）。
  var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  var autoscroll = FrameTicker()

  private func scheduleTick(_ generation: Int) {
    autoscroll.schedule { [weak self] in
      guard let self, autoscroll.generation == generation else { return }
      tick()
      scheduleTick(generation)
    }
  }

  /// 前のコマからの経過時間ぶん縦にスクロールし、見えている端の行まで伸ばす。速さ（行/秒）は外れた距離と見えている行数で
  /// 決まる（VS Code の `_getScrollSpeed`）。
  private func tick() {
    guard let edge, let source, let scrollView = textView.enclosingScrollView else { return }
    let current = now()
    let elapsed = current - lastTick
    lastTick = current
    let lineHeight = style.lineHeight
    let viewportLines = bounds.height / lineHeight
    let outside = edge.distance / lineHeight
    let speed =
      outside <= 1.5
      ? max(30, viewportLines * (1 + outside))
      : outside <= 3
        ? max(60, viewportLines * (2 + outside)) : max(200, viewportLines * (7 + outside))
    let delta = speed * CGFloat(elapsed) * lineHeight
    // `scroll(to:)` はスクロールできる範囲に収めないので、先に clip の制約（上端 0 と最終行を最上段まで）に通す。端に
    // 着いたら動かず、見えている端の行まで伸ばすだけになる。
    let clip = scrollView.contentView
    var proposed = clip.bounds
    proposed.origin.y += edge.above ? -delta : delta
    clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
    scrollView.reflectScrolledClipView(clip)
    guard let line = line(atY: edge.above ? bounds.minY : bounds.maxY - 0.5, source) else { return }
    extend(to: line, source)
  }

  /// 起点の区間から `line` まで行単位で選ぶ——`line` が起点の行より下なら起点の先頭からその行の終わりまで、上ならその
  /// 行頭から起点の終わりまで（動く側の端は先頭）、同じ行なら起点そのもの（VS Code の `cursorMoveCommands.line`）。
  private func extend(to line: Int, _ source: LineSource) {
    guard let anchor else { return }
    let anchorLine = source.line(containing: anchor.location)
    let target = source.range(ofLine: line)
    let range: NSRange
    let upstream: Bool
    if line < anchorLine {
      range = NSRange(location: target.location, length: NSMaxRange(anchor) - target.location)
      upstream = true
    } else if line > anchorLine {
      range = NSRange(location: anchor.location, length: NSMaxRange(target) - anchor.location)
      upstream = false
    } else {
      range = anchor
      upstream = false
    }
    textView.select(range, upstream: upstream)
    lastSelection = (range, anchor)
  }

  /// y（文書の座標）の行。最終行より下なら最終行、先頭より上なら先頭の行。
  private func line(atY y: CGFloat, _ source: LineSource) -> Int? {
    let geometry = VisibleLines(textView: textView)
    guard geometry.documentLength > 0 else { return 0 }
    return geometry.line(atY: y).map { source.line(containing: $0.start) }
  }
}

/// 次のコマで 1 回走らせる予約。`generation` を進めると、予約済みのものは走らせない側（受け手）が捨てる。
@MainActor
struct FrameTicker {
  var generation = 0
  var schedule: (@escaping @MainActor () -> Void) -> Void = { fire in
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { MainActor.assumeIsolated(fire) }
  }
}
