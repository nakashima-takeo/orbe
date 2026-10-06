import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// ドラッグの自動スクロール——ドラッグが本文の上下左右の外へ出ている間、ポインタが止まっていても VS Code の速さの式で
/// 刻みごとに送り、選択を伸ばし続ける（刻みは view の display link）。区画の文の選択は上下にだけ送る。
extension MouseSelection {
  func autoscroll(_ edge: Edge) {
    self.edge = edge
    guard link == nil, let view else { return }
    lastFrame = nil
    let link = view.displayLink(target: self, selector: #selector(step(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stopAutoscroll() {
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
    if case .zoneText = drag {
      let y = edge.isAbove ? surface.config.topInset : view.bounds.height - 0.5
      surface.inputScope {
        surface.transact(scrollTo: p) {
          surface.extendZoneSelection(to: CGPoint(x: point.x, y: y), position: p)
        }
      }
      return
    }
    let target: CGPoint
    let lineEnd: Bool?
    switch edge {
    case .above:
      target = CGPoint(x: point.x, y: surface.config.topInset)
      lineEnd = false
    case .below:
      target = CGPoint(x: point.x, y: view.bounds.height - 0.5)
      let lastRow = (site?.currentContent?.text.lineCount ?? 1) - 1
      lineEnd = (site?.hit(target, position: p)?.row ?? lastRow) < lastRow ? nil : true
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
