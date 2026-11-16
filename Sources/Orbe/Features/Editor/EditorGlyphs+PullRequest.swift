import SwiftUI

/// PR のパネルの印（見本 editor/parts.tsx の SVG の写し）。
extension EditorGlyphs {
  /// レールの「プルリクエスト」（24 系・stroke 1.5。見本 RailPrIcon）。
  static let railPullRequest = Glyph(viewBox: 24, stroke: 1.5) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    for (x, y) in [(7.0, 6.0), (7.0, 18.0), (17.0, 18.0)] as [(CGFloat, CGFloat)] {
      path.addEllipse(in: CGRect(x: (x - 2) * k, y: (y - 2) * k, width: 4 * k, height: 4 * k))
    }
    path.move(to: p(7, 8))
    path.addLine(to: p(7, 16))
    path.move(to: p(17, 16))
    path.addLine(to: p(17, 11))
    path.addArc(tangent1End: p(17, 8.5), tangent2End: p(14.5, 8.5), radius: 2.5 * k)
    path.addLine(to: p(11, 8.5))
    path.move(to: p(13, 6))
    path.addLine(to: p(10.5, 8.5))
    path.addLine(to: p(13, 11))
    return [(path, 1)]
  }

  /// open の PR（stroke 1.4。見本 PrOpenIcon）。
  static let pullRequest = Glyph(viewBox: 16, stroke: 1.4) { k in
    var path = pullRequestBranches(k)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    path.move(to: p(9.2, 4.6))
    path.addLine(to: p(7.4, 6.4))
    path.addLine(to: p(9.2, 8.2))
    return [(path, 1)]
  }

  /// プルリクエストを作成（stroke 1.5。見本 PrCreateIcon）。
  static let createPullRequest = Glyph(viewBox: 16, stroke: 1.5) { k in
    var path = pullRequestBranches(k)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    path.move(to: p(8, 4.5))
    path.addLine(to: p(8, 8.5))
    path.move(to: p(6, 6.5))
    path.addLine(to: p(10, 6.5))
    return [(path, 1)]
  }

  /// ツリー表示（stroke 1.3。見本 TreeIcon）。
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

  /// リスト表示（stroke 1.3。見本 ListIcon）。
  static let viewAsList = Glyph(viewBox: 16, stroke: 1.3) { k in
    var path = Path()
    for y in [4, 8, 12] as [CGFloat] {
      path.move(to: CGPoint(x: 3 * k, y: y * k))
      path.addLine(to: CGPoint(x: 13 * k, y: y * k))
    }
    return [(path, 1)]
  }

  /// PR の印の 3 つの点と、2 本の枝（`PrOpenIcon`・`PrCreateIcon` に共通）。
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
