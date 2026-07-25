import XCTest

@testable import Orbe

/// 閉じたタブの復元スタック（⇧⌘T）の純ドメイン契約を固定する。
///
/// 観測可能な契約は「積むのは人のジェスチャで閉じたときだけ」「閉じた時の index と復元単位が残る」
/// 「LIFO・workspace ごとに独立・上限 10」「挿入位置のクランプ」の4つ。
/// TerminalController は window 未接続なら libghostty surface を生成しないため、ここでは純ロジックとして
/// 検証できる（GhosttyKit ランタイムは起動しない）。スタックのエントリは明示タイトルで区別する
/// （`tabState().explicitTitle` に載る）。
final class SessionStoreClosedTabsTests: XCTestCase {

  /// 明示タイトルで区別できるタブを 1 枚作る。
  private func tab(_ title: String) -> TerminalController {
    let tc = TerminalController()
    tc.explicitTitle = title
    return tc
  }

  /// 明示タイトルで区別できるタブを持つ workspace を組む。
  private func makeWorkspace(_ name: String, titles: [String]) -> Workspace {
    let ws = Workspace(name: name, rootPath: "/tmp")
    ws.tabs = titles.map(tab)
    return ws
  }

  // MARK: - 発火源による積む/積まない

  /// 人のジェスチャ（タブ行の中クリック・⌘W）で閉じたタブは復元単位ごと積まれる。
  func testGestureCloseIsPushedWithRestoreUnit() {
    let ws = makeWorkspace("ws", titles: ["a"])
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    _ = store.removeTab(ws.tabs[0], origin: .gesture)

    let closed = store.popClosedTab()
    XCTAssertEqual(closed?.state.explicitTitle, "a", "閉じたタブの復元単位が積まれる")
    XCTAssertEqual(closed?.state.tree, .leaf(cwd: nil, agent: nil), "分割ツリーも復元単位に載る")
  }

  /// シェル exit・エージェント終了（.process）と制御 API（.controlAPI）では積まない。
  func testNonGestureCloseIsNotPushed() {
    for origin in [TabCloseOrigin.process, .controlAPI] {
      let ws = makeWorkspace("ws", titles: ["a"])
      let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

      _ = store.removeTab(ws.tabs[0], origin: origin)

      XCTAssertNil(store.popClosedTab(), "\(origin) で落ちたタブは積まない（⇧⌘T は無反応）")
    }
  }

  /// 発火源の分類（積むのは人のジェスチャだけ）。
  func testOnlyGesturePushesRestoreStack() {
    XCTAssertTrue(TabCloseOrigin.gesture.pushesRestoreStack, "人のジェスチャは積む")
    XCTAssertFalse(TabCloseOrigin.process.pushesRestoreStack, "シェル exit・エージェント終了は積まない")
    XCTAssertFalse(TabCloseOrigin.controlAPI.pushesRestoreStack, "制御 API は経路を問わず積まない")
  }

  // MARK: - 閉じた位置の記録

  /// 先頭・中間・末尾のどこで閉じても、閉じた時点の index がそのまま残る。
  func testClosedIndexRecordsPositionAtCloseTime() {
    let titles = ["a", "b", "c"]
    for position in titles.indices {
      let ws = makeWorkspace("ws", titles: titles)
      let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

      _ = store.removeTab(ws.tabs[position], origin: .gesture)

      let closed = store.popClosedTab()
      XCTAssertEqual(closed?.index, position, "閉じた時の index を記録する")
      XCTAssertEqual(closed?.state.explicitTitle, titles[position], "index と復元単位が同じタブを指す")
    }
  }

  // MARK: - LIFO・上限・workspace ごとの独立

  /// 直近に閉じたものから戻る（LIFO）。空なら nil＝呼び出し側は無反応。
  func testPopReturnsMostRecentlyClosedAndNilWhenEmpty() {
    let ws = makeWorkspace("ws", titles: ["a", "b"])
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)
    XCTAssertNil(store.popClosedTab(), "何も閉じていなければ nil")

    _ = store.removeTab(ws.tabs[0], origin: .gesture)  // a
    _ = store.removeTab(ws.tabs[0], origin: .gesture)  // b（a を外した後の先頭）

    XCTAssertEqual(store.popClosedTab()?.state.explicitTitle, "b", "直近に閉じた b が先に戻る")
    XCTAssertEqual(store.popClosedTab()?.state.explicitTitle, "a", "次に a が戻る")
    XCTAssertNil(store.popClosedTab(), "汲み尽くしたら nil")
  }

  /// 上限 10。11 件目以降を積むと最古から落ち、残るのは新しい 10 件。
  func testStackKeepsNewestTenAndDropsOldest() {
    let titles = (0..<12).map { "t\($0)" }
    let ws = makeWorkspace("ws", titles: titles)
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    for _ in titles { _ = store.removeTab(ws.tabs[0], origin: .gesture) }

    var popped: [String] = []
    while let closed = store.popClosedTab() { popped.append(closed.state.explicitTitle ?? "") }
    XCTAssertEqual(
      popped, Array(titles.dropFirst(2).reversed()),
      "最古 2 件は捨てられ、新しい 10 件が LIFO で戻る")
  }

  /// スタックは workspace ごとに独立（A で閉じたタブが B で復活しない）。
  func testStacksAreIndependentPerWorkspace() {
    let alpha = makeWorkspace("alpha", titles: ["a"])
    let beta = makeWorkspace("beta", titles: ["b"])
    let store = SessionStore(workspaces: [alpha, beta], activeWorkspace: 0)

    _ = store.removeTab(alpha.tabs[0], origin: .gesture)

    store.setActiveWorkspace(1)
    XCTAssertNil(store.popClosedTab(), "A で閉じたタブは B では戻せない")
    store.setActiveWorkspace(0)
    XCTAssertEqual(store.popClosedTab()?.state.explicitTitle, "a", "A へ戻れば A のスタックから戻せる")
  }

  // MARK: - 挿入位置のクランプ

  /// 指定した index にタブが挿さり、後続が 1 つ後ろへ押し出される。
  /// 中間を叩くのが要点——先頭・末尾だけだと `insert(at: 0)` や `append` の決め打ちと区別できず、
  /// 戻り値が合っているだけで「閉じた位置へ戻す」が壊れていても気づけない。
  func testInsertLandsAtGivenIndexAndShiftsFollowers() {
    let ws = makeWorkspace("ws", titles: ["a", "b", "c"])
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    XCTAssertEqual(store.insertTabIntoActive(tab("mid"), at: 1), 1, "戻り値は実挿入 index")

    XCTAssertEqual(
      ws.tabs.map(\.explicitTitle), ["a", "mid", "b", "c"], "指定 index へ挿さり後続が押し出される")
  }

  /// 有効範囲外の index は 0…count へクランプし、戻り値は実挿入 index。クランプ先へ実際に挿さる。
  func testInsertClampsToValidRangeAndReturnsActualIndex() {
    let ws = makeWorkspace("ws", titles: ["a", "b"])
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    XCTAssertEqual(store.insertTabIntoActive(tab("head"), at: -3), 0, "負値は先頭へクランプ")
    XCTAssertEqual(store.insertTabIntoActive(tab("tail"), at: 99), 3, "count 超は末尾へクランプ")
    XCTAssertEqual(
      ws.tabs.map(\.explicitTitle), ["head", "a", "b", "tail"], "クランプ先の位置へ実際に挿さる")
  }

  /// 0タブ（休眠）workspace への挿入は index 0 に着地し、active がそのタブを指す。
  func testInsertIntoEmptyWorkspaceLandsAtZero() {
    let ws = makeWorkspace("ws", titles: [])
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    XCTAssertEqual(store.insertTabIntoActive(tab("only"), at: 5), 0, "0タブでは index 0 へ")
    XCTAssertEqual(ws.active, 0, "active は唯一のタブを指す（範囲外に飛ばない）")
  }

  /// 挿入位置が現 active より前なら、active は挿入前と同じタブを指し続ける。
  func testInsertBeforeActiveKeepsActiveOnSameTab() {
    let ws = makeWorkspace("ws", titles: ["a", "b"])
    ws.active = 1
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    XCTAssertEqual(store.insertTabIntoActive(tab("head"), at: 0), 0)
    XCTAssertEqual(ws.tabs[ws.active].explicitTitle, "b", "active は挿入前と同じタブを指す")
  }

  /// 挿入位置が現 active と同値のときも同じタブを指し続ける（`dest <= active` の境界）。
  /// ここを `<` に緩めると、復元したタブが割り込んだ分だけ選択が 1 つ手前へずれる。
  func testInsertAtActiveIndexKeepsActiveOnSameTab() {
    let ws = makeWorkspace("ws", titles: ["a", "b"])
    ws.active = 1
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    XCTAssertEqual(store.insertTabIntoActive(tab("mid"), at: 1), 1)

    XCTAssertEqual(ws.tabs.map(\.explicitTitle), ["a", "mid", "b"])
    XCTAssertEqual(ws.tabs[ws.active].explicitTitle, "b", "active は挿入前と同じタブを指す")
  }
}
