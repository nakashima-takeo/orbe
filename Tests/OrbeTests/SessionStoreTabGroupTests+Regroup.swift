import XCTest

@testable import Orbe

/// cd 再判定（`regroup`）。`groupKey` が変わった後に呼ばれ、不変条件が破れているときだけタブを
/// 動かす——「動かなくてよいものを動かさない」。
extension SessionStoreTabGroupTests {

  /// 連の中で別 worktree へ cd し、その worktree の連が他所にあれば、その連の右端へ移る。
  func testRegroupMovesStrayTabToEndOfItsPeersSegment() {
    let store = makeStore(["a", "a", "a", "b", "b"])
    let moved = store.current.tabs[1]
    moved.groupKey = "b"

    XCTAssertEqual(store.regroup(moved), 0, "動かしたので所属 workspace index")
    XCTAssertEqual(keys(store.current), ["a", "a", "b", "b", "b"], "b の連の右端へ")
    XCTAssertTrue(store.current.tabs[4] === moved)
  }

  /// 連の中で、どこにも連の無い worktree（管理外含む）へ cd したときだけ、その連の直右へ出る（Q2）。
  func testRegroupEjectsSplittingTabToRightOfItsFormerSegment() {
    let store = makeStore(["a", "a", "a", "b"])
    let moved = store.current.tabs[1]
    moved.groupKey = "z"

    XCTAssertEqual(store.regroup(moved), 0)
    XCTAssertEqual(keys(store.current), ["a", "a", "z", "b"], "元の連の直右")
  }

  /// 単独セグメントのタブは、キーが変わっても位置を変えない（Q2: その場に留まりキーだけ変わる）。
  func testRegroupLeavesSingletonInPlace() {
    let store = makeStore(["a", "b", "c"])
    let tab = store.current.tabs[1]
    tab.groupKey = "z"

    XCTAssertNil(store.regroup(tab), "不変条件は破れていない＝動かさない")
    XCTAssertEqual(keys(store.current), ["a", "z", "c"])
  }

  /// 連の端のタブが別キーへ変わっても、連を割らず・他所に同キーが無ければ動かない。
  func testRegroupLeavesEdgeTabInPlaceWhenInvariantHolds() {
    let store = makeStore(["a", "a", "b"])
    let tab = store.current.tabs[1]
    tab.groupKey = "z"

    XCTAssertNil(store.regroup(tab))
    XCTAssertEqual(keys(store.current), ["a", "z", "b"])
  }

  /// 連を割っていて、かつ他所にその key の連もあるなら、直右ではなく同キーの連へ合流する。
  func testRegroupPrefersJoiningPeersOverEjecting() {
    let store = makeStore(["b", "a", "a", "a"])
    let moved = store.current.tabs[2]
    moved.groupKey = "b"

    XCTAssertEqual(store.regroup(moved), 0)
    XCTAssertEqual(keys(store.current), ["b", "b", "a", "a"], "b の連の右端（直右 index 3 ではない）")
  }

  /// 他のタブが動いて index がずれても、active は同じタブを指し続ける。
  func testRegroupKeepsActiveOnSameTabWhenAnotherTabMoves() {
    let store = makeStore(["a", "a", "a", "b"], active: 2)
    let viewed = activeTab(store.current)
    let moved = store.current.tabs[0]
    moved.groupKey = "b"

    XCTAssertEqual(store.regroup(moved), 0)
    XCTAssertTrue(activeTab(store.current) === viewed, "index がずれても同じタブ")
    XCTAssertEqual(store.current.active, 1)
  }

  /// 動いたのが active 自身なら、active は移動後の自分を指す（cd したタブを見続ける）。
  func testRegroupFollowsActiveTabWhenItMoves() {
    let store = makeStore(["a", "a", "a", "b"], active: 0)
    let moved = activeTab(store.current)
    moved.groupKey = "b"

    XCTAssertEqual(store.regroup(moved), 0)
    XCTAssertTrue(activeTab(store.current) === moved, "移動後の自分")
    XCTAssertEqual(store.current.active, 3)
  }

  /// 背景 workspace のタブでも扱い、その workspace index を返す（アクティブ側の chrome には触れない）。
  func testRegroupHandlesBackgroundWorkspaceAndReportsItsIndex() {
    let background = workspace(["a", "a", "a", "b"])
    let store = SessionStore(workspaces: [workspace(["x"]), background], activeWorkspace: 0)
    let moved = background.tabs[1]
    moved.groupKey = "b"

    XCTAssertEqual(store.regroup(moved), 1, "背景 workspace の index")
    XCTAssertEqual(keys(background), ["a", "a", "b", "b"])
  }

  /// どの workspace にも無いタブ（閉鎖直後に届いた遅延 OSC 7）は nil で、配列に触れない。
  func testRegroupIgnoresUnknownTab() {
    let store = makeStore(["a", "b"])
    let before = store.current.tabs

    XCTAssertNil(store.regroup(tab("a")))
    XCTAssertTrue(store.current.tabs.elementsEqual(before, by: ===))
  }
}
