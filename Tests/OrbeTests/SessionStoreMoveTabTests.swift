import XCTest

@testable import Orbe

/// SessionStore.moveTab(from:to:) の純ドメイン契約を固定する。
///
/// moveTab はアクティブ workspace 内でタブを `from` から `to`（挿入先 index・挿入前基準）へ動かす。
/// 移動先は掴んだタブの連（同 `groupKey` の隣接列）の中に限る——連をまたぐ拒否と連ごとの移動は
/// `SessionStoreTabGroupTests+Reorder` が持つ。観測可能な契約は「戻り値（実移動したか）」「tabs の並び（TerminalTab の同一性順）」
/// 「active が指す TerminalTab（index ではなく参照が追従するか）」の3つ。
/// TerminalTab は window 未接続なら libghostty surface を生成しないため、ここでは純ロジックとして
/// トポロジーだけ検証できる（GhosttyKit ランタイムは起動しない）。
final class SessionStoreMoveTabTests: OrbeTestCase {

  /// n 本のタブを持つアクティブ workspace 1つだけの SessionStore を組む。
  /// 返す配列は各タブの参照（同一性で並びと参照追従を照合するため）。
  /// 全タブ同 cwd＝1 セグメントなので、連ガードは素通り（0…count のどこへでも動かせる）。
  private func makeStore(tabCount n: Int, active: Int = 0) -> (SessionStore, [TerminalTab]) {
    let ws = Workspace(name: "ws", rootPath: "/tmp")
    let tabs = (0..<n).map { _ in TerminalTab(cwd: "/tmp") }
    ws.tabs = tabs
    ws.selection = .tab(ws.tabs[active])
    return (SessionStore(workspaces: [ws], activeWorkspace: 0), tabs)
  }

  // MARK: - 並び替え（配列順）

  /// from < to：掴んだタブが後方の挿入先へ入り、間のタブが前へ詰める。
  func testMoveForwardReordersTabs() {
    let (store, t) = makeStore(tabCount: 4)  // [0,1,2,3]
    XCTAssertTrue(store.moveTab(from: 0, to: 2), "実移動なので true")
    XCTAssertTrue(
      store.current.tabs.elementsEqual([t[1], t[0], t[2], t[3]], by: ===),
      "tab0 を挿入先 index2（1 と 2 の間）へ → [1,0,2,3]")
  }

  /// from > to：掴んだタブが前方の挿入先へ入り、間のタブが後ろへずれる。
  func testMoveBackwardReordersTabs() {
    let (store, t) = makeStore(tabCount: 4)  // [0,1,2,3]
    XCTAssertTrue(store.moveTab(from: 3, to: 1), "実移動なので true")
    XCTAssertTrue(
      store.current.tabs.elementsEqual([t[0], t[3], t[1], t[2]], by: ===),
      "tab3 を挿入先 index1 へ → [0,3,1,2]")
  }

  /// 末尾への移動（to == count）も範囲内で受け付ける。
  func testMoveToEndReordersTabs() {
    let (store, t) = makeStore(tabCount: 4)  // [0,1,2,3]
    XCTAssertTrue(store.moveTab(from: 0, to: 4), "to==count は範囲内 → true")
    XCTAssertTrue(
      store.current.tabs.elementsEqual([t[1], t[2], t[3], t[0]], by: ===),
      "tab0 を末尾へ → [1,2,3,0]")
  }

  // MARK: - active の参照追従

  /// 掴んだタブ自身がアクティブなら、active は移動後の自分自身を指し続ける。
  func testMovingActiveTabItselfKeepsActiveOnIt() {
    let (store, t) = makeStore(tabCount: 4, active: 0)  // active = tab0
    XCTAssertTrue(store.moveTab(from: 0, to: 4))  // tab0 を末尾へ → [1,2,3,0]
    XCTAssertTrue(store.current.selectedTab === t[0], "active は移動後の tab0 を指す")
    XCTAssertEqual(store.current.selectedTabIndex, 3, "tab0 の新 index=3")
  }

  /// 他タブの移動でアクティブの index がずれても、active は同じ TerminalTab を指し続ける。
  /// アクティブ(tab1)の前にいた tab0 をアクティブより後ろへ動かす → tab1 の index が 1→0 に繰り上がる。
  func testMovingOtherTabKeepsActiveOnSameController() {
    let (store, t) = makeStore(tabCount: 4, active: 1)  // active = tab1
    XCTAssertTrue(store.moveTab(from: 0, to: 4))  // tab0 を末尾へ → [1,2,3,0]
    XCTAssertTrue(store.current.selectedTab === t[1], "active は依然 tab1 を指す")
    XCTAssertEqual(store.current.selectedTabIndex, 0, "tab1 の index が 1→0 に追従")
  }

  // MARK: - no-op（false・配列不変）

  /// 同位置（to == from）と自分の直後（to == from+1。from を抜いた後の実挿入先が from と同じ）は
  /// 実移動なしで false、配列は変わらない。
  func testDropOnItsOwnPositionIsNoOp() {
    let (store, t) = makeStore(tabCount: 4)
    XCTAssertFalse(store.moveTab(from: 1, to: 1), "同位置は false")
    XCTAssertFalse(store.moveTab(from: 1, to: 2), "自分の直後へのドロップは実移動なし → false")
    XCTAssertTrue(store.current.tabs.elementsEqual(t, by: ===), "配列は不変")
  }

  // MARK: - 範囲外（false・配列不変）

  /// from が範囲外（from == count・負）か、to が 0…count の外なら false・配列不変。
  func testOutOfRangeIsRejected() {
    let (store, t) = makeStore(tabCount: 3)
    XCTAssertFalse(store.moveTab(from: 3, to: 0), "from==count は範囲外 → false")
    XCTAssertFalse(store.moveTab(from: -1, to: 0), "負の from → false")
    XCTAssertFalse(store.moveTab(from: 0, to: 4), "to>count は範囲外 → false")
    XCTAssertFalse(store.moveTab(from: 0, to: -1), "負の to → false")
    XCTAssertTrue(store.current.tabs.elementsEqual(t, by: ===), "配列は不変")
  }
}
