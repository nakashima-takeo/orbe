import CoreGraphics
import SwiftUI
import XCTest

@testable import Orbe

/// octicon グリフ（GitGlyph / OcticonPath）の幾何ロジック検証（design 正典 `StatusIcons.tsx` 移植の配線を固定）。
/// グリフの見た目・形状一致は 視覚突合の領域でありここでは扱わない（純幾何のみ）。
final class GitGlyphTests: XCTestCase {
  private let eps = 1e-6

  // MARK: - issue: 同心円 3 枚（even-odd）

  /// issue は viewBox 16 いっぱいの外周円を持ち、size でそのまま比例する。
  func testIssueBoundsScaleWithSize() {
    let base = GitGlyph.issue(size: 16).boundingRect
    XCTAssertEqual(base.minX, 0, accuracy: eps)
    XCTAssertEqual(base.minY, 0, accuracy: eps)
    XCTAssertEqual(base.width, 16, accuracy: eps)
    XCTAssertEqual(base.height, 16, accuracy: eps)

    let doubled = GitGlyph.issue(size: 32).boundingRect
    XCTAssertEqual(doubled.width, 32, accuracy: eps, "size に比例してスケールする")
    XCTAssertEqual(doubled.height, 32, accuracy: eps)
  }

  // MARK: - branch: OcticonPath 移植（原典 d 文字列が正典）

  /// branch は viewBox 16 内に収まり、size でそのまま比例する（d 文字列＋パーサの結合を固定）。
  func testBranchBoundsStayInViewBoxAndScale() {
    let base = GitGlyph.branch(size: 16).boundingRect
    XCTAssertFalse(base.isEmpty, "パースに失敗すると空 Path になる")
    XCTAssertTrue(CGRect(x: 0, y: 0, width: 16, height: 16).contains(base), "viewBox 16 内")

    let doubled = GitGlyph.branch(size: 32).boundingRect
    XCTAssertEqual(doubled.minX, base.minX * 2, accuracy: eps, "size に比例してスケールする")
    XCTAssertEqual(doubled.minY, base.minY * 2, accuracy: eps)
    XCTAssertEqual(doubled.width, base.width * 2, accuracy: eps)
    XCTAssertEqual(doubled.height, base.height * 2, accuracy: eps)
  }

  // MARK: - OcticonPath: d 文字列パーサ

  /// 絶対/相対の M・h・v・l と Z を頂点列で固定する（size=16 ⇒ viewBox 等倍）。
  func testParsesBasicCommands() {
    let verts = pathPoints(OcticonPath.path("M1 2h3v4l-2 1Z", size: 16))
    XCTAssertEqual(verts.count, 4)
    assertPointEqual(verts[0], CGPoint(x: 1, y: 2), "M（絶対 move）")
    assertPointEqual(verts[1], CGPoint(x: 4, y: 2), "h（相対水平線）")
    assertPointEqual(verts[2], CGPoint(x: 4, y: 6), "v（相対垂直線）")
    assertPointEqual(verts[3], CGPoint(x: 2, y: 7), "l（相対線）")
  }

  /// 小数点で結合した数値（`9.573.677`）を 2 値に分解する（octicon の d に頻出）。
  func testTokenizerSplitsJoinedDecimals() {
    let verts = pathPoints(OcticonPath.path("M9.573.677L10 2", size: 16))
    XCTAssertEqual(verts.count, 2)
    assertPointEqual(verts[0], CGPoint(x: 9.573, y: 0.677), "結合数値の分解")
    assertPointEqual(verts[1], CGPoint(x: 10, y: 2), "L（絶対線）")
  }

  /// 円弧（A・端点→中心変換）は指定した終点で正確に閉じる。
  func testArcEndsAtEndpoint() throws {
    let verts = pathPoints(OcticonPath.path("M0 0A1 1 0 0 1 1 1", size: 16))
    let last = try XCTUnwrap(verts.last)
    assertPointEqual(last, CGPoint(x: 1, y: 1), "円弧の終点")
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
