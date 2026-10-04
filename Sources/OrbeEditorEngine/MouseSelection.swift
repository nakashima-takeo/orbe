import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// マウスの選択の状態機械——クリックの回数で単位（文字・語・行・全体）を決め、その後のドラッグと ⇧クリックは起点の範囲と
/// 単位を保って伸ばす（VS Code の `SelectionStartKind`）。4 回以上のクリックの全体はドラッグで縮めない。行番号の列は行の
/// 単位。ドラッグが本文の上下左右の外へ出ると、ポインタが止まっていても VS Code の速さの式で自動スクロールし、選択が伸び
/// 続ける（刻みは view の display link）。外へ出たときに伸ばす先は VS Code と同じ——上は見えている上端の行の行頭、下は
/// 下端の行のポインタの桁（最終行が見えればその行末）、左はポインタの行の行頭、右は行末。⌘だけのクリックが URL に当たれば、
/// 離したときに開く（動けば開かない。その間は選択が伸びない）。選択の字の上の 1 回のクリック（⇧・⌘ なし）は本文のドラッグ
/// の候補で、押した位置から 4pt を越えて動かせば文字のドラッグが始まり（時間の待ちは置かない）、越えずに離せばその位置に
/// キャレットを置く。
///
/// ⌥（⌘・⇧・⌃ なし）の押下はカーソルを足す（VS Code の `CreateCursor` と `LastCursor*Select`）。押したときに「押す前の他の
/// カーソル」と「動かす 1 本」に分け、ドラッグと自動スクロールは動かす 1 本だけを今の単位で伸ばして、その都度 2 つを合わせて
/// 置く（途中で重なってまとまっても、戻せば元に分かれる）。素の押下は他のカーソルが空の同じ形。⌥ の 2 回目・3 回目の押下は、
/// 1 回目の押下の前の列に、押した位置の語・行を足し直す。カーソルが 2 本以上で、足すはずのカーソルの動く端がどれかの選択の
/// 中（両端を含む）なら、足さずにそのカーソルを外す（その後のドラッグは無い）。⌥ の押下は選択の上でも本文のドラッグの候補に
/// しない。
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
  /// 押す前の他のカーソル（列の順）と、押して動かしている 1 本。
  private var others: [Cursor] = []
  private var moving: Cursor?
  /// ⌥ の押下の続き（2 回目・3 回目の押下）が足し直す、1 回目の押下の前の列。
  private var optionBase: [Cursor]?
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
    guard let hit = surface.hit(point), hit.area != .marks, hit.area != .overview,
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
    let current = surface.editor.state.cursors
    let primary = current.primary
    let shift = flags.contains(.shift)
    let adds =
      flags.contains(.option) && flags.isDisjoint(with: [.command, .shift])
      && (hit.area == .numbers || event.clickCount <= 3)
    let selection = primary.selection
    if hit.area == .text, event.clickCount == 1,
      flags.isDisjoint(with: [.shift, .command, .option]),
      selection.length > 0, hit.offset >= selection.location, hit.offset <= NSMaxRange(selection),
      surface.character(at: point) != nil
    {
      drag = .candidate(hit.offset, event.locationInWindow)
      return
    }
    let (cursor, reveal) = pressed(hit, clicks: event.clickCount, shift: shift, from: primary, text)
    guard adds else {
      optionBase = nil
      press(others: [], moving: cursor, reveal: reveal)
      return
    }
    if event.clickCount == 1 || hit.area == .numbers {
      if removeCursor(at: cursor.position, from: current) { return }
      optionBase = current.all
    }
    guard let base = optionBase else {
      drag = nil
      return
    }
    press(others: base, moving: cursor, reveal: reveal)
  }

  /// 押した場所・回数で決まる、動かす 1 本と見せ方（⇧ なら主から伸ばす）。ドラッグの単位も置く。
  private func pressed(
    _ hit: PointerHit, clicks: Int, shift: Bool, from primary: Cursor, _ text: TextRope
  ) -> (Cursor, Reveal) {
    if hit.area == .numbers {
      drag = .numbers
      return (
        shift ? EditCommands.extendByLine(primary, toRow: hit.row, text) : Self.line(hit.row, text),
        .minimal
      )
    }
    drag = .text
    switch clicks {
    case ...1: return (shift ? Self.extend(primary, to: hit, text) : Cursor(hit.offset), .minimal)
    case 2:
      return (
        shift
          ? EditCommands.extendByWord(primary, to: hit.offset, text)
          : EditCommands.wordSelection(at: hit.offset, text), .minimal
      )
    case 3:
      return (
        shift
          ? EditCommands.extendByLine(primary, toRow: hit.row, text) : Self.line(hit.row, text),
        .minimal
      )
    default:
      drag = nil
      return (.selecting(NSRange(location: 0, length: text.length)), .none)
    }
  }

  /// カーソルが 2 本以上で、`offset` を選択の中（両端を含む）に持つカーソルがあれば外す（VS Code の `CreateCursor`）。
  private func removeCursor(at offset: Int, from cursors: CursorList) -> Bool {
    guard cursors.count > 1,
      let index = cursors.all.firstIndex(where: {
        $0.selection.location <= offset && offset <= NSMaxRange($0.selection)
      })
    else { return false }
    drag = nil
    optionBase = nil
    var remaining = cursors.all
    remaining.remove(at: index)
    if let list = CursorList(remaining) { surface?.editor.select(list, reveal: .none) }
    return true
  }

  /// 押す前の他のカーソル `others` に、動かす 1 本 `moving` を足して置き、動かす 1 本を見せる。
  private func press(others: [Cursor], moving: Cursor, reveal: Reveal) {
    self.others = others
    self.moving = moving
    place(reveal: reveal)
  }

  /// 他のカーソルと動かす 1 本を合わせて置く（重なればまとまる）。
  private func place(reveal: Reveal) {
    guard let surface, let moving, let list = CursorList(others + [moving]) else { return }
    surface.editor.select(list, reveal: reveal, of: NSRange(location: moving.position, length: 0))
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
    let area = surface.surfaceLayout.text
    let column = area.minX
    if point.y < surface.config.topInset {
      autoscroll(.above(surface.config.topInset - point.y))
    } else if point.y > view.bounds.height {
      autoscroll(.below(point.y - view.bounds.height))
    } else if point.x < column {
      autoscroll(.left(column - point.x))
      extend(to: point, lineEnd: false, reveal: .none)
    } else if point.x > area.maxX {
      autoscroll(.right(point.x - area.maxX))
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
    others = []
    moving = nil
  }

  /// ポインタの形と URL の下線——行番号と印の列は矢印、本文は I ビーム、⌘ を押して URL の上なら指（面に焦点があるとき）。
  /// ⌘ を押している間は本文の上のポインタの位置を面へ渡し、下線はその位置の下の URL に描画スレッドがそのコマの配置で
  /// 引く。スクロールで URL の矩形が動くので、矩形は登録せずその場の当たりで決める。
  func updatePointer(at windowPoint: NSPoint, flags: NSEvent.ModifierFlags, in view: NSView) {
    guard let surface else { return }
    let point = view.convert(windowPoint, from: nil)
    let hit = view.bounds.contains(point) ? surface.hit(point) : nil
    let armed = flags.contains(.command) && hit?.area == .text
    surface.setLinkPointer(armed ? point : nil)
    guard let hit else { return }
    if hit.area != .text {
      NSCursor.arrow.set()
    } else if armed, surface.focused, surface.link(at: point) != nil {
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
    guard let surface, let drag, let moving, let text = surface.currentContent?.text,
      var hit = surface.hit(point, position: position)
    else { return }
    if let lineEnd {
      let content = text.contentRange(ofRow: hit.row)
      hit.offset = lineEnd ? NSMaxRange(content) : content.location
    }
    if case .numbers = drag {
      self.moving = EditCommands.extendByLine(moving, toRow: hit.row, text)
    } else {
      self.moving = Self.extend(moving, to: hit, text)
    }
    place(reveal: reveal)
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
