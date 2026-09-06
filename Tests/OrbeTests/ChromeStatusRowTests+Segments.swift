import SwiftUI
import XCTest

@testable import Orbe

/// セグメント化されたタブ行の幅計算と幾何（純関数 `StatusTabLayout`）。
/// 識別バー（2 枚以上の連の左端 3px）は器の床に含める＝room から引く。
extension ChromeStatusRowTests {

  private var gap: CGFloat { Chrome.tabGap }
  private var plus: CGFloat { Chrome.tabHeight }
  private var bar: CGFloat { DSSegmentBar.width }

  // MARK: - widths

  /// 溢れたとき、room はセグメント間の隙間・＋ボタン・**2 枚以上の連のバー幅**を引いた値。
  /// 単独タブはバーを持たないので引かれない。
  func testOverflowRoomSubtractsBarWidthOnlyForMultiTabSegments() {
    let naturals: [CGFloat] = [100, 100, 100, 100]
    let available: CGFloat = 300
    let segments: [Range<Int>] = [0..<2, 2..<3, 3..<4]  // 連 1 本（バー 1）＋単独 2

    let widths = StatusTabLayout.widths(
      naturals: naturals, segments: segments, available: available)

    let room = available - gap * 3 - plus - bar
    XCTAssertEqual(widths.reduce(0, +), room, accuracy: 0.5, "隙間 3・＋・バー 1 本ぶんを引いた room")
    for w in widths { XCTAssertGreaterThanOrEqual(w, Chrome.tabMinWidth, "床は保つ") }
  }

  /// 同じタブ列でも、全部が 1 本の連ならバー 1 本・隙間 1 つだけ。セグメント構造が room を変える。
  func testSegmentStructureChangesRoom() {
    let naturals: [CGFloat] = [100, 100, 100, 100]
    let available: CGFloat = 300

    let oneRun = StatusTabLayout.widths(naturals: naturals, segments: [0..<4], available: available)
    let singles = StatusTabLayout.widths(
      naturals: naturals, segments: StatusTabLayout.singletons(count: 4), available: available)

    XCTAssertEqual(oneRun.reduce(0, +), available - gap - plus - bar, accuracy: 0.5, "連 1 本")
    XCTAssertEqual(singles.reduce(0, +), available - gap * 4 - plus, accuracy: 0.5, "単独 4 はバー無し")
  }

  /// 収まるときはセグメント構造に関わらず自然幅。
  func testFittingTabsKeepNaturalWidthRegardlessOfSegments() {
    let naturals: [CGFloat] = [100, 100, 100]
    let widths = StatusTabLayout.widths(naturals: naturals, segments: [0..<3], available: 800)
    XCTAssertEqual(widths, naturals)
  }

  /// 床 40 は shrink 時だけの下限ではなくセルの幅そのものの床。行に余っていても、2 文字のタブは
  /// 自然幅（数十 pt）ではなく 40 で立つ。上限 140 は逆側の同じ規則。
  func testShortAndLongNaturalsClampToFloorAndCapWhenFitting() {
    let widths = StatusTabLayout.widths(
      naturals: [18, 40, 100, 300], segments: StatusTabLayout.singletons(count: 4), available: 800)
    XCTAssertEqual(widths, [Chrome.tabMinWidth, 40, 100, Chrome.tabMaxWidth])
  }

  // MARK: - geometry

  /// x 積算: 連の先頭でバー幅ぶん進み、連の中は隙間なし、連と連の間だけ tabGap。
  /// セグメント幅はバー＋セル合計、rowEnd は最後のセグメントの右端。
  func testGeometryPlacesBarCellsAndGaps() {
    let geo = StatusTabLayout.geometry(widths: [50, 60, 70], segments: [0..<2, 2..<3])

    XCTAssertEqual(geo.cells.map(\.x), [bar, bar + 50, bar + 110 + gap], "バーの後に隙間なし、次の連は +gap")
    XCTAssertEqual(geo.cells.map(\.width), [50, 60, 70])
    XCTAssertEqual(geo.segments.map(\.x), [0, bar + 110 + gap])
    XCTAssertEqual(geo.segments.map(\.width), [bar + 110, 70], "連 = バー + Σセル、単独はセルだけ")
    XCTAssertEqual(geo.segments.map(\.isGroup), [true, false], "グループは 2 枚以上の連だけ")
    XCTAssertEqual(geo.rowEnd, bar + 110 + gap + 70)
    XCTAssertEqual(geo.count, 3, "タブ総数＝末尾への挿入 index")
  }

  /// 0 タブは空の幾何（rowEnd 0）。
  func testGeometryOfNoTabsIsEmpty() {
    let geo = StatusTabLayout.geometry(widths: [], segments: [])
    XCTAssertTrue(geo.cells.isEmpty)
    XCTAssertEqual(geo.rowEnd, 0)
  }
}
