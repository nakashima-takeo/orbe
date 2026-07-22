import CoreGraphics
import SwiftUI
import XCTest

@testable import Orbe

/// ステータスグリフの幾何ロジック検証（design 正典 `StatusIcons.tsx` 座標移植の配線を固定）。
/// グリフの見た目・形状一致は 視覚突合の領域でありここでは扱わない（純幾何のみ）。
final class StatusGlyphTests: XCTestCase {
  private let eps = 1e-6

  // MARK: - done: 角丸四角＋check 線

  /// doneSquare は viewBox rect x1 y1 8×8 を size 倍で置く（size=10 ⇒ そのまま）。
  func testDoneSquareBounds() {
    let rect = StatusGlyphShape.doneSquare(size: 10).boundingRect
    XCTAssertEqual(rect.minX, 1, accuracy: eps)
    XCTAssertEqual(rect.minY, 1, accuracy: eps)
    XCTAssertEqual(rect.width, 8, accuracy: eps)
    XCTAssertEqual(rect.height, 8, accuracy: eps)
  }

  /// doneCheck は 3 頂点 M2.8 5.2 → L4.4 6.8 → L7.4 3.4 を size/10 倍で結ぶ。
  func testDoneCheckVertices() {
    let verts = pathPoints(StatusGlyphShape.doneCheck(size: 20))  // k=2
    XCTAssertEqual(verts.count, 3)
    assertPointEqual(verts[0], CGPoint(x: 5.6, y: 10.4), "始点")
    assertPointEqual(verts[1], CGPoint(x: 8.8, y: 13.6), "谷")
    assertPointEqual(verts[2], CGPoint(x: 14.8, y: 6.8), "終点")
  }

  // MARK: - idle/dormant: zzz

  /// zzz は 3 本の z（大/中/小）。stroke 幅は 1.1 > 0.9 > 0.75（size=10 ⇒ k=1）で単調減少。
  func testZzzWidthsDescend() {
    let zs = StatusGlyphShape.zzz(size: 10)
    XCTAssertEqual(zs.count, 3)
    XCTAssertEqual(zs[0].width, 1.1, accuracy: eps)
    XCTAssertEqual(zs[1].width, 0.9, accuracy: eps)
    XCTAssertEqual(zs[2].width, 0.75, accuracy: eps)
  }

  /// 各 z は 4 頂点の折れ線（M H L H）。先頭 z の頂点を固定する。
  func testZzzFirstStrokeVertices() {
    let verts = pathPoints(StatusGlyphShape.zzz(size: 10)[0].path)
    XCTAssertEqual(verts.count, 4)
    assertPointEqual(verts[0], CGPoint(x: 0.8, y: 4.6), "上辺始点")
    assertPointEqual(verts[1], CGPoint(x: 4.2, y: 4.6), "上辺終点")
    assertPointEqual(verts[2], CGPoint(x: 0.8, y: 8.4), "斜線")
    assertPointEqual(verts[3], CGPoint(x: 4.2, y: 8.4), "下辺終点")
  }

  // MARK: - helpers

  private func assertPointEqual(
    _ a: CGPoint, _ b: CGPoint, _ msg: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(a.x, b.x, accuracy: eps, msg, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: eps, msg, file: file, line: line)
  }

  /// Path の move/line 頂点を順に取り出す（closeSubpath は座標を持たないので除外）。
  private func pathPoints(_ path: Path) -> [CGPoint] {
    var pts: [CGPoint] = []
    path.cgPath.applyWithBlock { elementPtr in
      let e = elementPtr.pointee
      switch e.type {
      case .moveToPoint, .addLineToPoint:
        pts.append(e.points[0])
      default:
        break
      }
    }
    return pts
  }
}
