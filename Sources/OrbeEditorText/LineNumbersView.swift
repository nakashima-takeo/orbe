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
/// 番号を押すとその行を選ぶ（VS Code の既定: 押した行を起点に、ドラッグで行単位に伸ばし、本文の上下の外と行番号の上では
/// 自動スクロールで伸び続け、⇧で今の選択の元の区間から伸ばす。選択の動く側の端はポインタの側で、選んだ後はそこを見せる）。
/// 印の列は押しても何もしない。
final class LineNumbersView: NSView {
  private let textView: SurfaceTextView
  private let style: TextSurfaceStyle
  let marksView: LineMarksView
  weak var source: LineSource?
  /// 押してから離すまでの起点（行の選択が伸びる元の区間）。
  private var anchor: NSRange?
  /// 最後に列で選んだときの起点（その選択を伸ばしただけなら、⇧クリックはこの区間から伸ばす）。
  private var lineSelectionStart: NSRange?

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
    // ⌃クリックは行を選ばない（VS Code も mac の ⌃クリックを扱わない）。焦点も動かさない。
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard !flags.contains(.control) else { return }
    window?.makeFirstResponder(textView)
    anchor = flags.contains(.shift) ? selectionStart() : source.range(ofLine: line)
    extend(to: line, source)
    revealCaret()
  }

  /// VS Code の `mouseHandler` と同じく、本文の上下の外へ出たら縦に、行番号の上（本文の左の外）なら横に、ポインタが
  /// 止まっていても自動スクロールで伸び続ける。本文の上に出れば止めて、ポインタの行まで伸ばして動く側の端を見せる。
  override func mouseDragged(with event: NSEvent) {
    guard anchor != nil, let source else { return }
    let point = convert(event.locationInWindow, from: nil)
    if point.y < bounds.minY {
      autoscroll(.above(bounds.minY - point.y))
    } else if point.y > bounds.maxY {
      autoscroll(.below(point.y - bounds.maxY))
    } else if point.x <= bounds.width {
      autoscroll(.left(bounds.width - point.x, y: point.y))
      if let line = line(atY: point.y, source) { extend(to: line, source) }
    } else {
      stopAutoscroll()
      guard let line = line(atY: point.y, source) else { return }
      extend(to: line, source)
      revealCaret()
    }
  }

  override func mouseUp(with event: NSEvent) {
    anchor = nil
    stopAutoscroll()
  }

  /// 押している間に窓から外れると mouse-up は届かない（文書の切り替えが面を外す）ので、ここで選択の操作を終える。
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    guard newWindow == nil else { return }
    anchor = nil
    stopAutoscroll()
  }

  /// ⇧で伸ばす元の区間（VS Code の `selectionStart`）。列で行を選んだ後に選択を伸ばしただけ（⇧↓ など）なら、その行が
  /// 元の区間のまま。そうでなければ今の選択から決める——語や段落の単位で選んだ選択（ダブル・トリプルクリック）はその選択
  /// 全体、それ以外は動かない側の端。
  private func selectionStart() -> NSRange {
    let selection = textView.textSelection
    let caret = textView.caretLocation
    if let start = lineSelectionStart, Self.selection(from: start, to: caret) == selection {
      return start
    }
    if selection.length > 0,
      let granularity = textView.textLayoutManager.textSelections.last?.granularity,
      granularity != .character
    {
      return selection
    }
    let fixed = caret == selection.location ? NSMaxRange(selection) : selection.location
    return NSRange(location: fixed, length: 0)
  }

  /// 元の区間 `start` から `position` まで伸ばした選択（VS Code の `SingleCursorState._computeSelection`）——位置が
  /// 元の区間の先頭より前なら元の区間の終わりから、そうでなければ先頭から。
  private static func selection(from start: NSRange, to position: Int) -> NSRange {
    let fixed = start.length > 0 && position < start.location ? NSMaxRange(start) : start.location
    return NSRange(location: min(fixed, position), length: abs(position - fixed))
  }

  /// 起点の区間から `line` まで行単位で選ぶ（VS Code の `cursorMoveCommands.line`）——`line` が起点の行より上ならその
  /// 行頭まで、下ならその次の行頭まで、同じ行なら起点の終わりまで、動く側の端を動かす。
  private func extend(to line: Int, _ source: LineSource) {
    guard let anchor else { return }
    let anchorLine = source.line(containing: anchor.location)
    let target = source.range(ofLine: line)
    let position =
      line < anchorLine
      ? target.location : line > anchorLine ? NSMaxRange(target) : NSMaxRange(anchor)
    let range = Self.selection(from: anchor, to: position)
    textView.select(range, upstream: position < NSMaxRange(range))
    lineSelectionStart = anchor
  }

  /// 動く側の端が見えるところまで最小限スクロールする（VS Code は行の選択の後にカーソルを見せる）。
  private func revealCaret() {
    textView.scrollRangeToVisible(NSRange(location: textView.caretLocation, length: 0))
  }

  // MARK: - 自動スクロール

  /// ポインタが本文のどちら側に、どれだけ外れているか。横は行番号の上（本文の左の外）で、`y` はポインタの縦の位置
  /// （文書の座標）。
  private enum Edge {
    case above(CGFloat)
    case below(CGFloat)
    case left(CGFloat, y: CGFloat)
  }

  private var edge: Edge?
  /// 外へ出ている間、コマごとに `autoscrollFrame` を呼ぶ。
  private var clock: FrameClock?
  /// 前のコマの時刻（外へ出て最初のコマは時刻を取るだけ）。
  private var lastFrame: CFTimeInterval?

  /// 自動スクロールが回っているか。
  var isAutoscrolling: Bool { clock != nil }

  private func autoscroll(_ edge: Edge) {
    self.edge = edge
    guard clock == nil else { return }
    lastFrame = nil
    clock = FrameClock(view: self) { [unowned self] in autoscrollFrame(now: CACurrentMediaTime()) }
  }

  private func stopAutoscroll() {
    clock?.cancel()
    clock = nil
    edge = nil
  }

  /// 前のコマからの経過時間ぶんスクロールし、縦なら見えている端の行まで、横ならポインタの行まで伸ばす。速さは外れた距離と
  /// 見えている量で決まる（VS Code の `TopBottomDragScrolling` / `LeftRightDragScrolling`）。
  func autoscrollFrame(now: CFTimeInterval) {
    guard let edge, let source, let scrollView = textView.enclosingScrollView else { return }
    defer { lastFrame = now }
    guard let lastFrame else { return }
    let elapsed = CGFloat(now - lastFrame)
    let clip = scrollView.contentView
    var proposed = clip.bounds
    let line: Int?
    switch edge {
    case .above(let distance), .below(let distance):
      let lineHeight = style.lineHeight
      let delta =
        Self.speed(outside: distance / lineHeight, visible: bounds.height / lineHeight)
        * elapsed * lineHeight
      let above = if case .above = edge { true } else { false }
      proposed.origin.y += above ? -delta : delta
      line = nil
    case .left(let distance, let y):
      // 全角 1 字（半角 2 桁）を単位に数え、その半分ずつ送る。
      let fullWidth = 2 * style.font.cellWidth
      proposed.origin.x -=
        Self.speed(outside: distance / fullWidth, visible: clip.bounds.width / fullWidth)
        * elapsed * fullWidth * 0.5
      line = self.line(atY: y, source)
    }
    // `scroll(to:)` はスクロールできる範囲に収めないので、先に clip の制約（上端 0 と最終行を最上段まで、左端 0）に通す。
    // 端に着いたら動かず、伸ばすだけになる。
    clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
    scrollView.reflectScrolledClipView(clip)
    let edgeY: CGFloat
    switch edge {
    case .above: edgeY = bounds.minY
    case .below: edgeY = bounds.maxY - 0.5
    case .left(_, let y): edgeY = y
    }
    guard let target = line ?? self.line(atY: edgeY, source) else { return }
    extend(to: target, source)
  }

  /// 自動スクロールの速さ（単位/秒）。外れた距離と見えている量をどちらも同じ単位（行・全角の字）で数える。
  private static func speed(outside: CGFloat, visible: CGFloat) -> CGFloat {
    outside <= 1.5
      ? max(30, visible * (1 + outside))
      : outside <= 3 ? max(60, visible * (2 + outside)) : max(200, visible * (7 + outside))
  }

  /// y（文書の座標）の行。最終行より下なら最終行、先頭より上なら先頭の行。
  private func line(atY y: CGFloat, _ source: LineSource) -> Int? {
    let geometry = VisibleLines(textView: textView)
    guard geometry.documentLength > 0 else { return 0 }
    return geometry.line(atY: y).map { source.line(containing: $0.start) }
  }
}

/// display link 駆動でコマごとに `tick` を呼ぶ。
@MainActor
private final class FrameClock {
  private var link: CADisplayLink?
  private let tick: () -> Void

  init(view: NSView, tick: @escaping () -> Void) {
    self.tick = tick
    link = view.displayLink(target: self, selector: #selector(step))
    link?.add(to: .main, forMode: .common)
  }

  @objc private func step(_ link: CADisplayLink) { tick() }

  func cancel() {
    link?.invalidate()
    link = nil
  }
}
