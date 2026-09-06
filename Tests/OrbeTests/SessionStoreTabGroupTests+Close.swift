import XCTest

@testable import Orbe

/// 閉じたときのフォーカス先——セグメント内の右隣、無ければ左隣（Q4）。単独セグメントは現行どおり
/// （index 据え置き＝右隣、末尾は左へクランプ）。
extension SessionStoreTabGroupTests {

  /// 2 枚以上の連の右端（アクティブ）を閉じると、配列上の右隣（別の連）ではなく同じ連の左隣へ。
  func testClosingRightEndOfSegmentFocusesLeftNeighborInSameSegment() {
    let store = makeStore(["a", "a", "b"], active: 1)
    let left = store.current.tabs[0]

    guard
      case .reselectActive(let index) = store.removeTab(activeTab(store.current), origin: .gesture)
    else { return XCTFail("アクティブ workspace のタブを閉じたので reselectActive") }

    XCTAssertEqual(index, 0, "同じ連の左隣")
    XCTAssertTrue(activeTab(store.current) === left)
  }

  /// 連の中（右端でない）を閉じると右隣（同じ連）へ。
  func testClosingMiddleOfSegmentFocusesRightNeighbor() {
    let store = makeStore(["a", "a", "a", "b"], active: 1)
    let right = store.current.tabs[2]

    guard
      case .reselectActive(let index) = store.removeTab(activeTab(store.current), origin: .gesture)
    else { return XCTFail("reselectActive") }

    XCTAssertEqual(index, 1, "index 据え置き＝右隣")
    XCTAssertTrue(activeTab(store.current) === right)
  }

  /// 単独セグメントは現行どおり右隣（別の連でも）へ。
  func testClosingSingletonFocusesRightNeighborAcrossSegments() {
    let store = makeStore(["a", "b", "c", "c"], active: 1)
    let right = store.current.tabs[2]

    guard
      case .reselectActive(let index) = store.removeTab(activeTab(store.current), origin: .gesture)
    else { return XCTFail("reselectActive") }

    XCTAssertEqual(index, 1)
    XCTAssertTrue(activeTab(store.current) === right, "単独タブは連の規則を持たない")
  }

  /// アクティブでない連の右端を閉じても active は同じタブを指し続ける（分岐は閉じたのが active のときだけ）。
  func testClosingInactiveRightEndDoesNotMoveFocus() {
    let store = makeStore(["a", "a", "b"], active: 2)
    let viewed = activeTab(store.current)

    _ = store.removeTab(store.current.tabs[1], origin: .gesture)

    XCTAssertTrue(activeTab(store.current) === viewed, "active は同じタブ")
    XCTAssertEqual(store.current.active, 1, "index だけ繰り上がる")
  }
}
