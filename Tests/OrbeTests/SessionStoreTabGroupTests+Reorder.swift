import XCTest

@testable import Orbe

/// 並び替え——タブはセグメントの中だけ（`moveTab`）、セグメントは連ごと境界へ（`moveSegment`）。
/// 連の中の移動そのもの（方向・no-op・範囲外）は `SessionStoreMoveTabTests` が持つ。
extension SessionStoreTabGroupTests {

  // MARK: - moveTab（セグメント内に閉じる）

  /// 別セグメントへの挿入先は拒否され、配列は変わらない（不変条件を並び替えで破らせない）。
  func testMoveTabRejectsDestinationOutsideItsSegment() {
    let store = makeStore(["a", "a", "b", "b"])
    let before = store.current.tabs

    XCTAssertFalse(store.moveTab(from: 0, to: 4), "a を b の連の後ろへ → false")
    XCTAssertFalse(store.moveTab(from: 3, to: 1), "b を a の連の中へ → false")
    XCTAssertTrue(store.current.tabs.elementsEqual(before, by: ===), "配列は不変")
  }

  /// 自セグメントの中（右端への挿入 = upperBound を含む）は受理される。
  func testMoveTabAcceptsDestinationsWithinItsSegment() {
    let store = makeStore(["b", "a", "a", "a", "c"])
    let t = store.current.tabs

    XCTAssertTrue(store.moveTab(from: 1, to: 4), "連 1..<4 の右端（upperBound）への挿入")
    XCTAssertTrue(
      store.current.tabs.elementsEqual([t[0], t[2], t[3], t[1], t[4]], by: ===),
      "連の中で末尾へ回る")
  }

  // MARK: - moveSegment（連ごと境界へ）

  /// 連を丸ごと後ろの境界へ動かす。中の順序は保たれ、active は同じタブを指す。
  func testMoveSegmentForwardKeepsInnerOrderAndActiveTab() {
    let store = makeStore(["a", "a", "b", "c", "c"], active: 1)
    let t = store.current.tabs

    XCTAssertTrue(store.moveSegment(containing: 0, to: 3), "a の連を b の後ろ（境界 3）へ")
    XCTAssertTrue(
      store.current.tabs.elementsEqual([t[2], t[0], t[1], t[3], t[4]], by: ===),
      "[b, a, a, c, c]")
    XCTAssertTrue(activeTab(store.current) === t[1], "active は動いた連の中の同じタブ")
    XCTAssertEqual(store.current.active, 2)
  }

  /// 連を前の境界（先頭）へ動かす。掴んだのが連の中央のタブでも連全体が動く。
  func testMoveSegmentBackwardMovesWholeRun() {
    let store = makeStore(["a", "b", "b", "b"], active: 0)
    let t = store.current.tabs

    XCTAssertTrue(store.moveSegment(containing: 2, to: 0), "b の連を先頭へ")
    XCTAssertTrue(
      store.current.tabs.elementsEqual([t[1], t[2], t[3], t[0]], by: ===), "[b, b, b, a]")
    XCTAssertTrue(activeTab(store.current) === t[0], "他の連の移動でも active は同じタブ")
  }

  /// 末尾（to == count）もセグメント境界として受け付ける。
  func testMoveSegmentToEndIsABoundary() {
    let store = makeStore(["a", "a", "b"])
    let t = store.current.tabs

    XCTAssertTrue(store.moveSegment(containing: 0, to: 3))
    XCTAssertTrue(store.current.tabs.elementsEqual([t[2], t[0], t[1]], by: ===), "[b, a, a]")
  }

  /// 連の中（境界でない挿入先）は拒否される——連を割る位置には落とせない。
  func testMoveSegmentRejectsNonBoundaryDestination() {
    let store = makeStore(["a", "b", "b", "c"])
    let before = store.current.tabs

    XCTAssertFalse(store.moveSegment(containing: 0, to: 2), "b の連の中")
    XCTAssertTrue(store.current.tabs.elementsEqual(before, by: ===), "配列は不変")
  }

  /// 自連の両端（元の位置）は実移動なしで false。
  func testMoveSegmentToOwnBoundariesIsNoOp() {
    let store = makeStore(["a", "b", "b", "c"])
    let before = store.current.tabs

    XCTAssertFalse(store.moveSegment(containing: 1, to: 1), "自連の lowerBound")
    XCTAssertFalse(store.moveSegment(containing: 1, to: 3), "自連の upperBound")
    XCTAssertTrue(store.current.tabs.elementsEqual(before, by: ===), "配列は不変")
  }

  /// 範囲外は false・配列不変。
  func testMoveSegmentRejectsOutOfRange() {
    let store = makeStore(["a", "b"])
    let before = store.current.tabs

    XCTAssertFalse(store.moveSegment(containing: 2, to: 0), "from が範囲外")
    XCTAssertFalse(store.moveSegment(containing: 0, to: 3), "to > count")
    XCTAssertTrue(store.current.tabs.elementsEqual(before, by: ===), "配列は不変")
  }
}
