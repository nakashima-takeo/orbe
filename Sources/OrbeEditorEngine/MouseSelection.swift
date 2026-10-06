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
///
/// 押下は、押した点の行き先（→ `SurfaceTarget`）で振り分ける。本文・行番号の列・区画の空きは本文の場、入力欄はその場で
/// 選び（どちらも主をその場にする）、区画の選べる文は区画の文の選択（主を区画の文にする。ドラッグは同じ自動スクロールで
/// 伸びる）、押せる場所は押下を数えて同じ押せる場所で離せば載せる側へ知らせる（主は変えない。選べる文に重なる押せる場所は、
/// 4pt を越えてドラッグすれば選択になる）。
@MainActor
final class MouseSelection: NSObject {
  weak var surface: MetalTextSurface?
  /// 押して選んでいる場（押してから離すまで）。
  weak var site: EditingSite?

  enum Drag {
    case text
    case numbers
    case link(URL, NSPoint)
    /// 選択の字の上を押した（本文のドラッグの候補）。離したらキャレットを置く位置と、押した位置（窓の座標）。
    case candidate(Int, NSPoint)
    /// 区画の選べる文を選んでいる。
    case zoneText
    /// 押せる場所を押している。
    case button(ZonePress)
  }

  /// 押している押せる場所——区画・id・押した位置（窓の座標）と、重なる選べる文（まとまりと位置）。
  struct ZonePress {
    var zone: ObjectIdentifier
    var id: AnyHashable
    var down: NSPoint
    var text: (AnyHashable, Int)?
  }

  enum Edge {
    case above(CGFloat)
    case below(CGFloat)
    case left(CGFloat)
    case right(CGFloat)

    var isAbove: Bool {
      if case .above = self { return true }
      return false
    }
  }

  var drag: Drag?
  /// 押す前の他のカーソル（列の順）と、押して動かしている 1 本。
  private var others: [Cursor] = []
  private var moving: Cursor?
  /// ⌥ の 1 回目の押下がしたこと——足している（2 回目・3 回目の押下が足し直す、1 回目の押下の前の列）か、カーソルを
  /// 外したか。直前の押下が ⌥ の 1 回目でなければ nil。
  private enum OptionPress {
    case adding([Cursor])
    case removed
  }

  private var optionPress: OptionPress?
  /// 押したときの本文の版（押している間に本文が変われば、マウスの操作をそこで終える）。
  private var version: Int?
  var edge: Edge?
  var link: CADisplayLink?
  var lastFrame: CFTimeInterval?
  /// 最後のポインタの位置（view の座標）。
  var point = CGPoint.zero
  weak var view: NSView?
  /// 押してからこれ以上動けばドラッグ（URL を開かない・本文のドラッグを始める）。
  private static let clickSlop: CGFloat = 4

  /// 押した。点の下の行き先 `target` で振り分ける（⌃ の押下は右クリックのメニューに任せる）。
  func mouseDown(_ event: NSEvent, in view: NSView, target: SurfaceTarget) {
    guard let surface else { return }
    let control = event.modifierFlags.contains(.control)
    switch target {
    case .body, .zoneSpace:
      if !control { surface.setPrimary(.body) }
      mouseDown(event, in: view, site: surface.bodySite)
    case .field(let site):
      if !control, let field = site.field { surface.setPrimary(.field(field.id)) }
      mouseDown(event, in: view, site: site)
    case .zoneText(let entry, let text, let offset):
      cancel()
      optionPress = nil
      guard !control else { return }
      begin(event, in: view)
      drag = .zoneText
      surface.beginZoneSelection(
        entry, text: text, offset: offset, clicks: event.clickCount,
        extending: event.modifierFlags.contains(.shift))
    case .button(let entry, let button):
      cancel()
      optionPress = nil
      guard !control else { return }
      begin(event, in: view)
      let zone = ObjectIdentifier(entry.zone)
      drag = .button(
        ZonePress(
          zone: zone, id: button.id, down: event.locationInWindow,
          text: surface.zonePoint(point, in: zone).flatMap { entry.hits.text(at: $0) }))
    }
  }

  /// 押下を受け始める（焦点を取る）。
  private func begin(_ event: NSEvent, in view: NSView) {
    point = view.convert(event.locationInWindow, from: nil)
    self.view = view
    view.window?.makeFirstResponder(view)
  }

  private func mouseDown(_ event: NSEvent, in view: NSView, site: EditingSite) {
    cancel()
    let previous = optionPress
    optionPress = nil
    guard let surface else { return }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard !flags.contains(.control) else { return }
    point = view.convert(event.locationInWindow, from: nil)
    guard let hit = site.hit(point), hit.area != .marks, hit.area != .overview,
      let text = site.editingEnvironment()?.text
    else { return }
    self.site = site
    self.view = view
    view.window?.makeFirstResponder(view)
    if hit.area == .text, flags.intersection([.command, .shift, .option]) == .command,
      event.clickCount == 1, let url = surface.link(at: point)
    {
      drag = .link(url, event.locationInWindow)
      return
    }
    let current = site.editor.state.cursors
    let primary = current.primary
    let shift = flags.contains(.shift)
    let adds =
      flags.contains(.option) && flags.isDisjoint(with: [.command, .shift])
      && (hit.area == .numbers || event.clickCount <= 3)
    let selection = primary.selection
    if hit.area == .text, event.clickCount == 1,
      flags.isDisjoint(with: [.shift, .command, .option]),
      selection.length > 0, hit.offset >= selection.location, hit.offset <= NSMaxRange(selection),
      site.character(at: point) != nil
    {
      drag = .candidate(hit.offset, event.locationInWindow)
      return
    }
    version = site.currentContent?.version
    let (cursor, reveal) = pressed(hit, clicks: event.clickCount, shift: shift, from: primary, text)
    guard adds else { return press(others: [], moving: cursor, reveal: reveal) }
    if event.clickCount == 1 || hit.area == .numbers {
      if removeCursor(at: cursor.position, from: current) {
        optionPress = .removed
        return
      }
      optionPress = .adding(current.all)
      return press(others: current.all, moving: cursor, reveal: reveal)
    }
    optionPress = previous
    switch previous {
    case .adding(let base)?: press(others: base, moving: cursor, reveal: reveal)
    case .removed?: drag = nil
    case nil: press(others: [], moving: cursor, reveal: reveal)
    }
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
    var remaining = cursors.all
    remaining.remove(at: index)
    if let list = CursorList(remaining) { site?.editor.select(list, reveal: .none) }
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
    guard let site, let moving, let list = CursorList(others + [moving]) else { return }
    site.editor.select(list, reveal: reveal, of: NSRange(location: moving.position, length: 0))
  }

  func mouseDragged(_ event: NSEvent, in view: NSView) {
    guard let drag, let surface else { return }
    switch drag {
    case .link: return
    case .candidate(_, let down):
      guard Self.moved(event, from: down) > Self.clickSlop else { return }
      self.drag = nil
      surface.textView.beginTextDrag(with: event)
      return
    case .button(let press):
      guard Self.moved(event, from: press.down) > Self.clickSlop, let (text, offset) = press.text,
        let entry = surface.zones[press.zone]
      else { return }
      self.drag = .zoneText
      surface.beginZoneSelection(entry, text: text, offset: offset, clicks: 1, extending: false)
      return dragZoneText(event, in: view)
    case .zoneText:
      return dragZoneText(event, in: view)
    case .text, .numbers:
      break
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

  /// 区画の文の選択を点まで伸ばす。上下の外では自動スクロールする（区画は横に送らない）。
  private func dragZoneText(_ event: NSEvent, in view: NSView) {
    guard let surface else { return }
    point = view.convert(event.locationInWindow, from: nil)
    if point.y < surface.config.topInset {
      autoscroll(.above(surface.config.topInset - point.y))
    } else if point.y > view.bounds.height {
      autoscroll(.below(point.y - view.bounds.height))
    } else {
      stopAutoscroll()
      surface.extendZoneSelection(to: point)
    }
  }

  func mouseUp(_ event: NSEvent, in view: NSView) {
    stopAutoscroll()
    defer { drag = nil }
    if case .candidate(let offset, _) = drag {
      site?.editor.select(CursorList(Cursor(offset)), reveal: .minimal)
      return
    }
    if case .button(let press) = drag, let surface {
      let up = view.convert(event.locationInWindow, from: nil)
      guard case .button(let entry, let button) = surface.target(at: up),
        ObjectIdentifier(entry.zone) == press.zone, button.id == press.id
      else { return }
      surface.transact { entry.zone.zone(.pressed(press.id)) }
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
  func extend(
    to point: CGPoint, position: SIMD2<Double>? = nil, lineEnd: Bool? = nil, reveal: Reveal
  ) {
    guard let site, let drag, let moving, let content = site.currentContent,
      var hit = site.hit(point, position: position)
    else { return }
    guard content.version == version else { return cancel() }
    let text = content.text
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
}
