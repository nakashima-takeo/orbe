import SwiftUI

/// PR のパネル・上のバー・レビューのポップアップの印。
extension EditorGlyphs {
  /// open の PR（stroke 1.4）。
  static let pullRequest = Glyph(viewBox: 16, stroke: 1.4) { k in
    var path = pullRequestBranches(k)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    path.move(to: p(9.2, 4.6))
    path.addLine(to: p(7.4, 6.4))
    path.addLine(to: p(9.2, 8.2))
    return [(path, 1)]
  }

  /// ツリー表示（stroke 1.3）。
  static let viewAsTree = Glyph(viewBox: 16, stroke: 1.3) { k in
    var path = Path()
    for (from, to) in [((3, 3), (7, 3)), ((6, 8), (13, 8)), ((6, 13), (13, 13)), ((6, 3), (6, 13))]
      as [((CGFloat, CGFloat), (CGFloat, CGFloat))]
    {
      path.move(to: CGPoint(x: from.0 * k, y: from.1 * k))
      path.addLine(to: CGPoint(x: to.0 * k, y: to.1 * k))
    }
    return [(path, 1)]
  }

  /// リスト表示（stroke 1.3）。
  static let viewAsList = Glyph(viewBox: 16, stroke: 1.3) { k in
    var path = Path()
    for y in [4, 8, 12] as [CGFloat] {
      path.move(to: CGPoint(x: 3 * k, y: y * k))
      path.addLine(to: CGPoint(x: 13 * k, y: y * k))
    }
    return [(path, 1)]
  }

  /// コメント（stroke 1.4）。
  static let comment = Glyph(viewBox: 16, stroke: 1.4) { k in
    var path = Path()
    let points: [(CGFloat, CGFloat)] = [
      (2.5, 3.5), (13.5, 3.5), (13.5, 10.5), (7.5, 10.5), (5, 13), (5, 10.5), (2.5, 10.5),
    ]
    path.move(to: CGPoint(x: points[0].0 * k, y: points[0].1 * k))
    for (x, y) in points.dropFirst() { path.addLine(to: CGPoint(x: x * k, y: y * k)) }
    path.closeSubpath()
    return [(path, 1)]
  }

  /// 変更を依頼（`M8 2.5v5M5.5 5h5M5.5 11.5h5`。stroke 1.4）。
  static let requestChanges = Glyph(viewBox: 16, stroke: 1.4) { k in
    var path = Path()
    for (from, to) in [((8, 2.5), (8, 7.5)), ((5.5, 5), (10.5, 5)), ((5.5, 11.5), (10.5, 11.5))]
      as [((CGFloat, CGFloat), (CGFloat, CGFloat))]
    {
      path.move(to: CGPoint(x: from.0 * k, y: from.1 * k))
      path.addLine(to: CGPoint(x: to.0 * k, y: to.1 * k))
    }
    return [(path, 1)]
  }

  /// PR の印の 3 つの点と、2 本の枝。
  private static func pullRequestBranches(_ k: CGFloat) -> Path {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    for (x, y) in [(4.5, 4.0), (4.5, 12.0), (11.5, 12.0)] as [(CGFloat, CGFloat)] {
      path.addEllipse(
        in: CGRect(x: (x - 1.4) * k, y: (y - 1.4) * k, width: 2.8 * k, height: 2.8 * k))
    }
    path.move(to: p(4.5, 5.4))
    path.addLine(to: p(4.5, 10.6))
    path.move(to: p(11.5, 10.6))
    path.addLine(to: p(11.5, 8))
    path.addArc(tangent1End: p(11.5, 6.4), tangent2End: p(9.9, 6.4), radius: 1.6 * k)
    path.addLine(to: p(7.5, 6.4))
    return path
  }
}
