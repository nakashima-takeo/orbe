import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// ドラッグの自動スクロール——ドラッグが本文の上下左右の外へ出ている間、ポインタが止まっていても VS Code の速さの式で
/// 刻みごとに送り、選択を伸ばし続ける（刻みは view の display link）。絵の差し込みの文の選択と、行の頭の印を引いて作る範囲は
/// 上下にだけ送る。
extension MouseSelection {
  /// ドラッグが出ている本文の外の側と、外へ出た距離（pt）。
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

  /// 前のコマからの経過時間ぶんスクロールし、上なら見えている上端の段の頭（折り返さない行では行頭）、下なら見えている下端の
  /// 行のポインタの桁（最終行の最後の段が見えればその行末）、横ならポインタの行（左は行頭、右は行末）まで伸ばす。スクロールと
  /// 選択は 1 つの取引で置く。
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
    switch drag {
    case .zoneText, .leadingMark:
      return extendVertically(edge, at: p, in: view)
    default: break
    }
    let target: CGPoint
    let lineEnd: Bool?
    switch edge {
    case .above:
      target = CGPoint(x: point.x, y: surface.config.topInset)
      lineEnd = false
    case .below:
      target = CGPoint(x: point.x, y: view.bounds.height - 0.5)
      let hit = site?.hit(target, position: p)
      lineEnd = Self.isLastSegment(hit, site?.currentContent?.text, surface.rows) ? true : nil
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

  /// 縦にだけ送るドラッグ（絵の差し込みの文の選択・行の頭の印の範囲）を、位置 `p` へ送り、見えている上端か下端まで伸ばす。
  /// スクロールと伸ばすのは 1 つの取引で置く。
  private func extendVertically(_ edge: Edge, at p: SIMD2<Double>, in view: NSView) {
    guard let surface else { return }
    let y = edge.isAbove ? surface.config.topInset : view.bounds.height - 0.5
    let target = CGPoint(x: point.x, y: y)
    surface.inputScope {
      surface.transact(scrollTo: p) {
        if case .leadingMark = drag {
          surface.extendLeadingMarkDrag(to: target, position: p)
        } else {
          surface.extendZoneSelection(to: target, position: p)
        }
      }
    }
  }

  /// 当たり `hit` が、最終行の最後の段か（当たりが無いか、本文が無ければ真）。
  static func isLastSegment(_ hit: PointerHit?, _ text: TextRope?, _ rows: RowLayout) -> Bool {
    guard let hit, let text else { return true }
    guard hit.row >= text.lineCount - 1 else { return false }
    let column = hit.offset - text.lineStart(hit.row)
    return rows.segment(containing: column, line: hit.row, upstream: hit.upstream)
      == rows.segments(ofLine: hit.row) - 1
  }

  /// 当たり `hit` を、その行の行末（`lineEnd`）か、その段の頭（折り返さない行では行頭）にしたもの。
  static func edge(of hit: PointerHit, lineEnd: Bool, _ text: TextRope, _ rows: RowLayout)
    -> PointerHit
  {
    var result = hit
    let content = text.contentRange(ofRow: hit.row)
    if lineEnd {
      result.offset = NSMaxRange(content)
    } else {
      let segment = rows.segment(
        containing: hit.offset - content.location, line: hit.row, upstream: hit.upstream)
      result.offset = content.location + (rows.wrap(ofLine: hit.row)?.start(of: segment) ?? 0)
    }
    result.upstream = false
    return result
  }
}
