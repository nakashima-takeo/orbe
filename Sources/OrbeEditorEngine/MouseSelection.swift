import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// 面の上の場所——行番号の数字の列・git の印の列・本文（最終行より下の空き地を含む）。
enum PointerArea {
  case numbers, marks, text
}

/// view の点を本文の言葉にしたもの。
struct PointerHit {
  var area: PointerArea
  var row: Int
  /// いちばん近い書記素の境（最終行より下なら本文の終わり）。
  var offset: Int
}

extension MetalTextSurface {
  /// view の点（flipped、pt）の場所。行は `y = 行 × 行高` で、推定が無い——遠くへ飛んだ直後でも、ポインタの下の行・字に
  /// 当たる。`position` はスクロールの位置（省けば今の位置）。
  func hit(_ point: CGPoint, position: SIMD2<Double>? = nil) -> PointerHit? {
    guard let env = editingEnvironment() else { return nil }
    let text = env.text
    let p = position ?? scrollPosition
    let column = config.columnWidth(lineCount: text.lineCount)
    let area: PointerArea =
      point.x < column - config.marks.gutterWidth ? .numbers : point.x < column ? .marks : .text
    let y = Double(point.y - config.topInset) + p.y
    let lineHeight = Double(config.lineHeight)
    guard y < Double(text.lineCount) * lineHeight else {
      return PointerHit(area: area, row: text.lineCount - 1, offset: text.length)
    }
    let row = min(max(0, Int((y / lineHeight).rounded(.down))), text.lineCount - 1)
    let x = CGFloat(Double(point.x - column) + p.x)
    return PointerHit(
      area: area, row: row, offset: text.lineStart(row) + env.geometry.column(atX: x, row: row))
  }

  /// 点を含む書記素。点が行の字の上でなければ（行番号の列・行末より右・字の無い行・最終行より下の空き地）nil。当たりと
  /// 同じ組版の行から引くので、右から左の字の並びでも見た目の字に当たる。`position` はスクロールの位置（省けば今の位置）。
  func character(at point: CGPoint, position: SIMD2<Double>? = nil) -> NSRange? {
    guard let text = currentContent?.text else { return nil }
    let p = position ?? scrollPosition
    let column = config.columnWidth(lineCount: text.lineCount)
    let y = Double(point.y - config.topInset) + p.y
    let lineHeight = Double(config.lineHeight)
    guard point.x >= column, point.y >= config.topInset, y < Double(text.lineCount) * lineHeight
    else { return nil }
    let row = Int((y / lineHeight).rounded(.down))
    let x = CGFloat(Double(point.x - column) + p.x)
    let (source, start) = LineShaper.source(row: row, in: text)
    let stops = lineStops.stops(source, tabWidth: config.tabWidth(columns: indentation.unit))
    guard x < stops.width, let glyph = stops.glyph(atX: x) else { return nil }
    return text.grapheme(containing: start + stops.offsets[glyph])
  }

  /// 点の下の字が URL の中なら、その URL。
  func link(at point: CGPoint) -> URL? {
    guard let text = currentContent?.text, let character = character(at: point) else { return nil }
    let row = text.row(containing: character.location)
    let start = text.lineStart(row)
    let length = min(NSMaxRange(text.contentRange(ofRow: row)) - start, LineShaper.limit)
    let line = text.substring(NSRange(location: start, length: length))
    return LinkDetector.links(in: line).first {
      NSLocationInRange(character.location - start, $0.range)
    }?.url
  }
}

/// マウスの選択の状態機械——クリックの回数で単位（文字・語・行・全体）を決め、その後のドラッグと ⇧クリックは起点の範囲と
/// 単位を保って伸ばす（VS Code の `SelectionStartKind`）。4 回以上のクリックの全体はドラッグで縮めない。行番号の列は行の
/// 単位。ドラッグが本文の上下左右の外へ出ると、ポインタが止まっていても VS Code の速さの式で自動スクロールし、選択が伸び
/// 続ける（刻みは view の display link）。外へ出たときに伸ばす先は VS Code と同じ——上は見えている上端の行の行頭、下は
/// 下端の行のポインタの桁（最終行が見えればその行末）、左はポインタの行の行頭、右は行末。⌘だけのクリックが URL に当たれば、
/// 離したときに開く（動けば開かない。その間は選択が伸びない）。選択の字の上の 1 回のクリック（⇧・⌘ なし）は本文のドラッグ
/// の候補で、押した位置から 4pt を越えて動かせば文字のドラッグが始まり（時間の待ちは置かない）、越えずに離せばその位置に
/// キャレットを置く。
@MainActor
final class MouseSelection: NSObject {
  weak var surface: MetalTextSurface?

  private enum Drag {
    case text
    case numbers
    case link(URL, NSPoint)
    /// 選択の字の上を押した（本文のドラッグの候補）。離したらキャレットを置く位置と、押した位置（窓の座標）。
    case candidate(Int, NSPoint)
  }

  private enum Edge {
    case above(CGFloat)
    case below(CGFloat)
    case left(CGFloat)
    case right(CGFloat)
  }

  private var drag: Drag?
  private var edge: Edge?
  private var link: CADisplayLink?
  private var lastFrame: CFTimeInterval?
  /// 最後のポインタの位置（view の座標）。
  private var point = CGPoint.zero
  private weak var view: NSView?
  /// 押してからこれ以上動けばドラッグ（URL を開かない・本文のドラッグを始める）。
  private static let clickSlop: CGFloat = 4

  func mouseDown(_ event: NSEvent, in view: NSView) {
    cancel()
    guard let surface else { return }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard !flags.contains(.control) else { return }
    point = view.convert(event.locationInWindow, from: nil)
    guard let hit = surface.hit(point), hit.area != .marks,
      let text = surface.editingEnvironment()?.text
    else { return }
    self.view = view
    view.window?.makeFirstResponder(view)
    if hit.area == .text, flags.intersection([.command, .shift, .option]) == .command,
      event.clickCount == 1, let url = surface.link(at: point)
    {
      drag = .link(url, event.locationInWindow)
      return
    }
    let primary = surface.editor.state.cursors.primary
    let shift = flags.contains(.shift)
    let selection = primary.selection
    if hit.area == .text, event.clickCount == 1, flags.isDisjoint(with: [.shift, .command]),
      selection.length > 0, hit.offset >= selection.location, hit.offset <= NSMaxRange(selection),
      surface.character(at: point) != nil
    {
      drag = .candidate(hit.offset, event.locationInWindow)
      return
    }
    let cursor: Cursor
    var reveal = Reveal.minimal
    if hit.area == .numbers {
      drag = .numbers
      cursor =
        shift ? EditCommands.extendByLine(primary, toRow: hit.row, text) : Self.line(hit.row, text)
    } else {
      drag = .text
      switch event.clickCount {
      case ...1: cursor = shift ? Self.extend(primary, to: hit, text) : Cursor(hit.offset)
      case 2:
        cursor =
          shift
          ? EditCommands.extendByWord(primary, to: hit.offset, text)
          : EditCommands.wordSelection(at: hit.offset, text)
      case 3:
        cursor =
          shift
          ? EditCommands.extendByLine(primary, toRow: hit.row, text) : Self.line(hit.row, text)
      default:
        drag = nil
        cursor = .selecting(NSRange(location: 0, length: text.length))
        reveal = .none
      }
    }
    surface.editor.select(CursorList(cursor), reveal: reveal)
  }

  func mouseDragged(_ event: NSEvent, in view: NSView) {
    guard let drag, let surface else { return }
    if case .link = drag { return }
    if case .candidate(_, let down) = drag {
      guard Self.moved(event, from: down) > Self.clickSlop else { return }
      self.drag = nil
      surface.textView.beginTextDrag(with: event)
      return
    }
    point = view.convert(event.locationInWindow, from: nil)
    let column = surface.config.columnWidth(
      lineCount: surface.editingEnvironment()?.text.lineCount ?? 1)
    if point.y < surface.config.topInset {
      autoscroll(.above(surface.config.topInset - point.y))
    } else if point.y > view.bounds.height {
      autoscroll(.below(point.y - view.bounds.height))
    } else if point.x < column {
      autoscroll(.left(column - point.x))
      extend(to: point, lineEnd: false, reveal: .none)
    } else if point.x > view.bounds.width {
      autoscroll(.right(point.x - view.bounds.width))
      extend(to: point, lineEnd: true, reveal: .none)
    } else {
      stopAutoscroll()
      extend(to: point, reveal: .minimal)
    }
  }

  /// 自動スクロールが回っているか。
  var isAutoscrolling: Bool { link != nil }

  func mouseUp(_ event: NSEvent, in view: NSView) {
    stopAutoscroll()
    defer { drag = nil }
    if case .candidate(let offset, _) = drag {
      surface?.editor.select(CursorList(Cursor(offset)), reveal: .minimal)
      return
    }
    guard case .link(let url, let down) = drag, let surface else { return }
    guard Self.moved(event, from: down) <= Self.clickSlop,
      surface.link(at: view.convert(event.locationInWindow, from: nil)) == url
    else { return }
    surface.host?.openLink(url)
  }

  /// 押した位置（窓の座標）から動いた距離。
  private static func moved(_ event: NSEvent, from down: NSPoint) -> CGFloat {
    hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y)
  }

  /// 押している間に窓から外れた（mouse-up が届かない）。
  func cancel() {
    stopAutoscroll()
    drag = nil
  }

  /// ポインタの形——行番号と印の列は矢印、本文は I ビーム、⌘ を押して URL の上なら指（面に焦点があるとき）。スクロールで
  /// URL の矩形が動くので、矩形は登録せずその場の当たりで決める。
  func updateCursor(at windowPoint: NSPoint, flags: NSEvent.ModifierFlags, in view: NSView) {
    guard let surface else { return }
    let point = view.convert(windowPoint, from: nil)
    guard view.bounds.contains(point), let hit = surface.hit(point) else { return }
    if hit.area != .text {
      NSCursor.arrow.set()
    } else if flags.contains(.command), surface.focused, surface.link(at: point) != nil {
      NSCursor.pointingHand.set()
    } else {
      NSCursor.iBeam.set()
    }
  }

  // MARK: - 伸ばす

  /// 行を改行まで選ぶ（単位は行）。
  private static func line(_ row: Int, _ text: TextRope) -> Cursor {
    let range = NSRange(
      location: text.lineStart(row), length: text.lineEnd(row) - text.lineStart(row))
    return Cursor(selectionStart: range, unit: .line, position: NSMaxRange(range))
  }

  /// 起点の範囲と単位を保って、当たった場所まで伸ばす。
  private static func extend(_ cursor: Cursor, to hit: PointerHit, _ text: TextRope) -> Cursor {
    switch cursor.unit {
    case .character: return cursor.moved(to: hit.offset, extending: true)
    case .word: return EditCommands.extendByWord(cursor, to: hit.offset, text)
    case .line: return EditCommands.extendByLine(cursor, toRow: hit.row, text)
    }
  }

  /// 点の下まで伸ばす。`lineEnd` を与えれば、点の行の行末（true）か行頭（false）まで。
  private func extend(
    to point: CGPoint, position: SIMD2<Double>? = nil, lineEnd: Bool? = nil, reveal: Reveal
  ) {
    guard let surface, let drag, let text = surface.currentContent?.text,
      var hit = surface.hit(point, position: position)
    else { return }
    if let lineEnd {
      let content = text.contentRange(ofRow: hit.row)
      hit.offset = lineEnd ? NSMaxRange(content) : content.location
    }
    let primary = surface.editor.state.cursors.primary
    let cursor: Cursor
    if case .numbers = drag {
      cursor = EditCommands.extendByLine(primary, toRow: hit.row, text)
    } else {
      cursor = Self.extend(primary, to: hit, text)
    }
    surface.editor.select(CursorList(cursor), reveal: reveal)
  }

  // MARK: - 自動スクロール

  private func autoscroll(_ edge: Edge) {
    self.edge = edge
    guard link == nil, let view else { return }
    lastFrame = nil
    let link = view.displayLink(target: self, selector: #selector(step(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  private func stopAutoscroll() {
    link?.invalidate()
    link = nil
    edge = nil
  }

  @objc private func step(_ link: CADisplayLink) {
    frame(now: CACurrentMediaTime())
  }

  /// 前のコマからの経過時間ぶんスクロールし、上なら見えている上端の行の行頭、下なら見えている下端の行のポインタの桁（最終行が
  /// 見えればその行末）、横ならポインタの行（左は行頭、右は行末）まで伸ばす。スクロールと選択は 1 つの取引で置く。
  func frame(now: CFTimeInterval) {
    guard let edge, let surface, let view else { return }
    defer { lastFrame = now }
    guard let lastFrame else { return }
    let elapsed = CGFloat(now - lastFrame)
    let (position, limits) = surface.scrollState(at: now)
    var p = position
    let lineHeight = surface.config.lineHeight
    let fullWidth = 2 * surface.config.cell
    let vertical = { (distance: CGFloat) in
      let visible = view.bounds.height - surface.config.topInset
      return Double(
        DragScrollSpeed.speed(outside: distance / lineHeight, visible: visible / lineHeight)
          * elapsed * lineHeight)
    }
    let horizontal = { (distance: CGFloat) in
      Double(
        DragScrollSpeed.speed(
          outside: distance / fullWidth, visible: CGFloat(limits.viewport.x) / fullWidth)
          * elapsed * fullWidth * 0.5)
    }
    switch edge {
    case .above(let distance): p.y -= vertical(distance)
    case .below(let distance): p.y += vertical(distance)
    case .left(let distance): p.x -= horizontal(distance)
    case .right(let distance): p.x += horizontal(distance)
    }
    p = simd_clamp(p, .zero, simd_max(limits.maximum, .zero))
    let target: CGPoint
    let lineEnd: Bool?
    switch edge {
    case .above:
      target = CGPoint(x: point.x, y: surface.config.topInset)
      lineEnd = false
    case .below:
      target = CGPoint(x: point.x, y: view.bounds.height - 0.5)
      let lastRow = (surface.currentContent?.text.lineCount ?? 1) - 1
      lineEnd = (surface.hit(target, position: p)?.row ?? lastRow) < lastRow ? nil : true
    case .left:
      target = point
      lineEnd = false
    case .right:
      target = point
      lineEnd = true
    }
    surface.inputScope {
      surface.transact(scrollTo: p) {
        extend(to: target, position: p, lineEnd: lineEnd, reveal: .none)
      }
    }
  }
}
