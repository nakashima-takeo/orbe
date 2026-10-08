import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// 本文のドラッグ＆ドロップ（AppKit のドラッグ）。同じ面の中は移動（⌥ でコピー）、他の文書・他のアプリへはコピーで出し、
/// 他のアプリの文字も受ける。Finder のファイルは載せる側へ「開く」を渡し、⇧ を押していればパスを入れる。落とす位置の印は
/// 描く材料に置き、本文の上下の端の 1 行の帯の中では自動でスクロールする。区画の入力欄へ落とせば入力欄に入れ（コピー。
/// 入力欄が主になる）、区画のほかの所（文・押せる場所・空き）へは落とせない。
extension MetalTextView: NSDraggingSource {
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .withinApplication ? [.move, .copy] : .copy
  }

  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    draggedRange = nil
  }

  /// 選択の文字のドラッグを始める（選択の上を押して動かした）。像は選択の見えている行の文字。
  func beginTextDrag(with event: NSEvent) {
    guard let surface, let text = surface.currentContent?.text else { return }
    let selection = surface.bodySite.editor.state.cursors.primary.selection
    guard selection.length > 0 else { return }
    draggedRange = selection
    let item = NSDraggingItem(pasteboardWriter: text.substring(selection) as NSString)
    let (frame, image) = dragImage(selection, text)
    item.setDraggingFrame(frame, contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  /// 選択の見えている行の文字を、本文と同じ位置に描いた像と、その矩形（view の座標）。
  private func dragImage(_ selection: NSRange, _ text: TextRope) -> (NSRect, NSImage) {
    guard let surface, let env = surface.bodySite.editingEnvironment() else {
      return (.zero, NSImage())
    }
    let config = surface.config
    let p = surface.scrollPosition
    let column = config.columnWidth(lineCount: text.lineCount)
    let layout = surface.rows
    let top = max(0, layout.line(atY: p.y))
    let bottom = layout.line(atY: p.y + Double(bounds.height))
    let rows = text.rows(of: selection).clamped(to: top...max(top, bottom))
    var pieces: [(String, CGPoint)] = []
    var frame = NSRect.null
    for row in rows {
      let start = text.lineStart(row)
      let from = max(selection.location, start)
      let to = min(NSMaxRange(selection), NSMaxRange(text.contentRange(ofRow: row)))
      let x0 = env.geometry.x(ofColumn: from - start, row: row)
      let x1 = env.geometry.x(ofColumn: max(from, to) - start, row: row)
      let origin = CGPoint(
        x: column + x0 - CGFloat(p.x),
        y: config.topInset + CGFloat(layout.y(ofLine: row) - p.y))
      pieces.append(
        (to > from ? text.substring(NSRange(location: from, length: to - from)) : "", origin))
      frame = frame.union(
        NSRect(origin: origin, size: CGSize(width: max(1, x1 - x0), height: config.lineHeight)))
    }
    guard !frame.isNull else { return (.zero, NSImage()) }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: config.font as NSFont, .foregroundColor: surface.textColor,
    ]
    let baseline = config.baseline - config.ascent
    let image = NSImage(size: frame.size, flipped: true) { _ in
      for (string, origin) in pieces {
        NSAttributedString(string: string, attributes: attributes).draw(
          at: CGPoint(x: origin.x - frame.minX, y: origin.y - frame.minY + baseline))
      }
      return true
    }
    return (frame, image)
  }

  // MARK: - 受ける

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    dropScrollTime = nil
    return draggingUpdated(sender)
  }

  /// 落とす位置の印を置き、端の帯の中なら自動でスクロールする（AppKit が周期で呼ぶ）。スクロールと印は 1 つの取引で置き、
  /// 当たりは取引の中で置いた位置で取る。右列（ミニマップと縦スクロールバー）の上は本文の外として扱い、送らず、戻ったとき
  /// 上にいた時間ぶん跳ばない。本文に重なる横スクロールバーの上は、落とさないが帯の中なら送る。
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard let surface else { return [] }
    var operation: NSDragOperation = []
    surface.input {
      let point = convert(sender.draggingLocation, from: nil)
      let area = overview.area(at: point)
      if area == .minimap || area == .vertical {
        dropScrollTime = nil
      } else {
        autoscrollDrop(at: point)
      }
      guard area == nil else { return showDrop(nil) }
      switch surface.target(at: point) {
      case .body:
        let drop = dropPlan(sender, site: surface.bodySite)
        showDrop(drop.indicator)
        operation = drop.operation
      case .field(let site):
        showDrop(nil)
        operation = dropPlan(sender, site: site).operation
      case .button, .zoneText, .zoneSpace:
        showDrop(nil)
      }
    }
    return operation
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    surface?.inputScope { showDrop(nil) }
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    surface?.inputScope { showDrop(nil) }
  }

  /// 落とす。ファイルを開くのは別の文書へ焦点を移すので、印を消してから載せる側へ渡す。
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let surface else { return false }
    var performed = false
    surface.inputScope { performed = performDrop(sender) }
    return performed
  }

  private func performDrop(_ sender: NSDraggingInfo) -> Bool {
    let point = convert(sender.draggingLocation, from: nil)
    guard let surface, overview.area(at: point) == nil else {
      showDrop(nil)
      return false
    }
    let site: EditingSite
    switch surface.target(at: point) {
    case .body: site = surface.bodySite
    case .field(let field): site = field
    case .button, .zoneText, .zoneSpace:
      showDrop(nil)
      return false
    }
    guard let action = dropPlan(sender, site: site).action else {
      showDrop(nil)
      return false
    }
    switch action {
    case .open(let urls):
      showDrop(nil)
      surface.host?.openFiles(urls)
    case .insertPaths(let urls, let offset):
      guard let host = surface.host else { return false }
      insertDrop(host.insertionText(forFiles: urls), at: offset, moving: nil, into: site)
    case .insert(let string, let offset, let moving):
      insertDrop(string, at: offset, moving: moving, into: site)
    }
    return true
  }

  /// 印を消す・焦点を取る・落とした場を主にする・入れるを 1 つの取引で行う。
  private func insertDrop(
    _ string: String, at offset: Int, moving: NSRange?, into site: EditingSite
  ) {
    guard let surface else { return }
    surface.input {
      showDrop(nil)
      window?.makeFirstResponder(self)
      surface.setPrimary(site.field.map { .field($0.id) } ?? .body)
      site.editor.perform(.drop(string, at: offset, moving: moving))
    }
  }

  /// 板と修飾と当たりを読んで、場 `site` へ落とすときの判断（`DropRules`）に渡す。運んでいる範囲は、本文の場へ落とす
  /// ときだけ見る（入力欄へは写す）。ファイルは本文の場だけが受ける（入力欄は文字だけ受ける）。
  private func dropPlan(_ info: NSDraggingInfo, site: EditingSite) -> DropPlan {
    guard let surface else { return DropPlan() }
    let point = convert(info.draggingLocation, from: nil)
    let board = info.draggingPasteboard
    let own = (info.draggingSource as? MetalTextView) === self && site.isBody
    return DropRules.plan(
      DropSituation(
        offset: site.hit(point, position: surface.scrollPosition)?.offset,
        files: fileURLs(on: board), string: board.string(forType: .string),
        dragged: own ? draggedRange : nil,
        copying: !info.draggingSourceOperationMask.contains(.move) || !site.isBody,
        shift: NSEvent.modifierFlags.contains(.shift),
        opensFiles: site.isBody && surface.host != nil))
  }

  private func showDrop(_ offset: Int?) {
    guard let surface, shownDrop != offset else { return }
    shownDrop = offset
    surface.write { $0.drop = offset }
  }

  /// 本文の上下の端から 1 行の帯の中にいる間、前の刻みからの経過時間ぶん、選択のドラッグと同じ速さの式でスクロールする。
  private func autoscrollDrop(at point: CGPoint) {
    guard let surface else { return }
    let now = CACurrentMediaTime()
    defer { dropScrollTime = now }
    let config = surface.config
    let band = config.lineHeight
    let depth: CGFloat
    if point.y < config.topInset + band {
      depth = -(config.topInset + band - point.y)
    } else if point.y > bounds.height - band {
      depth = point.y - (bounds.height - band)
    } else {
      return
    }
    guard let last = dropScrollTime else { return }
    let (position, limits) = surface.scrollState(at: now)
    let visible = (bounds.height - config.topInset) / band
    let speed = DragScrollSpeed.speed(outside: min(abs(depth), band) / band, visible: visible)
    var p = position
    p.y += Double((depth < 0 ? -speed : speed) * CGFloat(now - last) * band)
    surface.place(simd_clamp(p, .zero, simd_max(limits.maximum, .zero)))
  }
}
