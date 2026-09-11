import Foundation

/// CSS `cubic-bezier(x1, y1, x2, y2)` と同じ単位ベジェ。AppKit 側で自前補間するときに
/// `Theme.Motion` のイージング制御点をそのまま使う。
struct UnitBezier {
  let p1: CGPoint
  let p2: CGPoint

  /// 進行 `x`（0…1）に対する値 `y`（0…1）。
  func value(at x: CGFloat) -> CGFloat {
    let cx = 3 * p1.x
    let bx = 3 * (p2.x - p1.x) - cx
    let ax = 1 - cx - bx
    let cy = 3 * p1.y
    let by = 3 * (p2.y - p1.y) - cy
    let ay = 1 - cy - by
    func sampleX(_ t: CGFloat) -> CGFloat { ((ax * t + bx) * t + cx) * t }
    func sampleY(_ t: CGFloat) -> CGFloat { ((ay * t + by) * t + cy) * t }
    func slopeX(_ t: CGFloat) -> CGFloat { (3 * ax * t + 2 * bx) * t + cx }

    var t = x
    for _ in 0..<8 {
      let dx = sampleX(t) - x
      if abs(dx) < 1e-6 { return sampleY(t) }
      let d = slopeX(t)
      if abs(d) < 1e-6 { break }
      t -= dx / d
    }
    var lo: CGFloat = 0
    var hi: CGFloat = 1
    t = x
    while hi - lo > 1e-6 {
      t = (lo + hi) / 2
      if sampleX(t) < x { lo = t } else { hi = t }
    }
    return sampleY(t)
  }
}
