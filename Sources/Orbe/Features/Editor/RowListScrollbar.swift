import AppKit
import OrbeEditorCore

/// 行の列（`RowList`）のつまみ。列の子 view として clip view の上に重なり、frame がそのままつまみの矩形になる（トラックは
/// 描かない）。見せる規則と幾何は `SidebarScrollbar` が持ち、ここは列の出来事を渡して濃さの変化に写すだけ。当たりは
/// 見えている間のつまみだけで、つまみの上のホイールは responder の連鎖で列へ流れる。
final class RowListScrollbar: NSView {
  /// つまみのドラッグが求める位置（列が文書を送る）。
  var onScroll: ((CGFloat) -> Void)?
  private var visibility = SidebarScrollbar.Visibility()
  private var metrics = SidebarScrollbar.Metrics(position: 0, total: 0, visible: 0)
  private var shown = false
  private var pointerOver = false
  /// 押したときのポインタ（窓の座標）と幾何（ドラッグの起点）。
  private var grab: (y: CGFloat, geometry: ScrollbarGeometry)?
  private var pendingHide: DispatchWorkItem?

  override init(frame: NSRect) {
    super.init(frame: frame)
    alphaValue = 0
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
        owner: self))
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func draw(_ dirtyRect: NSRect) {
    SidebarScrollbar.thumbColor(pointerOver: pointerOver, dragging: grab != nil).setFill()
    bounds.fill()
  }

  /// 列の量が変わった（並べ直した・送った）。列の右端・全高をトラックにして、つまみを置き直す（列 NSScrollView は上が
  /// 原点）。
  func reflect(_ metrics: SidebarScrollbar.Metrics) {
    self.metrics = metrics
    visibility.scroll(to: metrics.position, at: SidebarScrollbar.now)
    let geometry = metrics.geometry
    if geometry.isNeeded, let track = superview?.bounds {
      let width = Theme.Layout.editorSidebarScrollbar
      frame = NSRect(
        x: track.maxX - width, y: track.minY + geometry.sliderPosition, width: width,
        height: geometry.sliderLength)
    }
    refresh()
  }

  /// ポインタが列に入った・出た。
  func hover(_ inside: Bool) {
    visibility.hover(inside, at: SidebarScrollbar.now)
    refresh()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    shown ? super.hitTest(point) : nil
  }

  override func mouseEntered(with event: NSEvent) {
    pointerOver = true
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    pointerOver = false
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    grab = (event.locationInWindow.y, metrics.geometry)
    visibility.drag(true, at: SidebarScrollbar.now)
    needsDisplay = true
    refresh()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let grab else { return }
    onScroll?(grab.geometry.position(afterDragging: grab.y - event.locationInWindow.y))
  }

  override func mouseUp(with event: NSEvent) {
    guard grab != nil else { return }
    grab = nil
    let now = SidebarScrollbar.now
    visibility.drag(false, at: now)
    if let list = superview {
      visibility.hover(
        list.bounds.contains(list.convert(event.locationInWindow, from: nil)), at: now)
    }
    needsDisplay = true
    refresh()
  }

  private func refresh() {
    let now = SidebarScrollbar.now
    let next = visibility.isShown(at: now) && metrics.geometry.isNeeded
    if next != shown {
      shown = next
      let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      NSAnimationContext.runAnimationGroup { context in
        context.duration = SidebarScrollbar.fadeDuration(toShown: next, reduceMotion: reduceMotion)
        context.timingFunction = CAMediaTimingFunction(name: .linear)
        animator().alphaValue = next ? 1 : 0
      }
    }
    pendingHide?.cancel()
    pendingHide = nil
    guard let hidesAt = visibility.hidesAt(now) else { return }
    let work = DispatchWorkItem { [weak self] in self?.refresh() }
    pendingHide = work
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, hidesAt - now), execute: work)
  }
}
