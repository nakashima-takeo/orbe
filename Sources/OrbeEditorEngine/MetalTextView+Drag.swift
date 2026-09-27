import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// 本文のドラッグ＆ドロップ（AppKit のドラッグ）。同じ面の中は移動（⌥ でコピー）、他の文書・他のアプリへはコピーで出し、
/// 他のアプリの文字も受ける。Finder のファイルは載せる側へ「開く」を渡し、⇧ を押していればパスを入れる。落とす位置の印は
/// 描く材料に置き、本文の上下の端の 1 行の帯の中では自動でスクロールする。
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
    let selection = surface.editor.state.cursors.primary.selection
    guard selection.length > 0 else { return }
    draggedRange = selection
    let item = NSDraggingItem(pasteboardWriter: text.substring(selection) as NSString)
    let (frame, image) = dragImage(selection, text)
    item.setDraggingFrame(frame, contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  /// 選択の見えている行の文字を、本文と同じ位置に描いた像と、その矩形（view の座標）。
  private func dragImage(_ selection: NSRange, _ text: TextRope) -> (NSRect, NSImage) {
    guard let surface, let env = surface.editingEnvironment() else { return (.zero, NSImage()) }
    let config = surface.config
    let p = surface.scrollPosition
    let column = config.columnWidth(lineCount: text.lineCount)
    let top = max(0, Int((p.y / Double(config.lineHeight)).rounded(.down)))
    let bottom = top + Int((Double(bounds.height) / Double(config.lineHeight)).rounded(.up))
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
        y: config.topInset + CGFloat(row) * config.lineHeight - CGFloat(p.y))
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

  /// 落とす位置の印を置き、端の帯の中なら自動でスクロールする（AppKit が周期で呼ぶ）。
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    let point = convert(sender.draggingLocation, from: nil)
    autoscrollDrop(at: point)
    let drop = dropPlan(sender)
    showDrop(drop.indicator)
    return drop.operation
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    showDrop(nil)
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    showDrop(nil)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let drop = dropPlan(sender)
    showDrop(nil)
    guard let surface, let action = drop.action else { return false }
    window?.makeFirstResponder(self)
    switch action {
    case .open(let urls):
      surface.host?.openFiles(urls)
    case .insert(let string, let offset, let moving):
      surface.perform(.drop(string, at: offset, moving: moving))
    }
    return true
  }

  /// 落としたときにすること。
  private enum DropAction {
    case open([URL])
    case insert(String, at: Int, moving: NSRange?)
  }

  /// 落とすときの操作・印・すること。
  private struct DropPlan {
    var operation: NSDragOperation = []
    var indicator: Int?
    var action: DropAction?
  }

  private func dropPlan(_ info: NSDraggingInfo) -> DropPlan {
    guard let surface, let hit = surface.hit(convert(info.draggingLocation, from: nil)) else {
      return DropPlan()
    }
    let board = info.draggingPasteboard
    if let urls = fileURLs(on: board) {
      guard let host = surface.host else { return DropPlan() }
      guard NSEvent.modifierFlags.contains(.shift) else {
        return DropPlan(operation: .copy, action: .open(urls))
      }
      return DropPlan(
        operation: .copy, indicator: hit.offset,
        action: .insert(host.insertionText(forFiles: urls), at: hit.offset, moving: nil))
    }
    guard let string = board.string(forType: .string) else { return DropPlan() }
    guard (info.draggingSource as? MetalTextView) === self, let dragged = draggedRange else {
      return DropPlan(
        operation: .copy, indicator: hit.offset,
        action: .insert(string, at: hit.offset, moving: nil))
    }
    let copy = !info.draggingSourceOperationMask.contains(.move)
    let edge = hit.offset == dragged.location || hit.offset == NSMaxRange(dragged)
    let inside = hit.offset >= dragged.location && hit.offset <= NSMaxRange(dragged)
    guard !inside || (copy && edge) else { return DropPlan() }
    return DropPlan(
      operation: copy ? .copy : .move, indicator: hit.offset,
      action: .insert(string, at: hit.offset, moving: copy ? nil : dragged))
  }

  private func showDrop(_ offset: Int?) {
    guard let surface, surface.material.read().drop != offset else { return }
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
    let (position, limits) = surface.scroll.peek(at: now)
    let visible = (bounds.height - config.topInset) / band
    let speed = DragScrollSpeed.speed(outside: min(abs(depth), band) / band, visible: visible)
    var p = position
    p.y += Double((depth < 0 ? -speed : speed) * CGFloat(now - last) * band)
    surface.place(simd_clamp(p, .zero, simd_max(limits.maximum, .zero)))
  }
}
