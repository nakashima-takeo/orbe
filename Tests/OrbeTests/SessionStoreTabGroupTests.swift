import XCTest

@testable import Orbe

/// タブ配列の隣接不変条件「同じ `groupKey` のタブは配列上で必ず隣接する」を `SessionStore` が
/// 唯一の保証者として守る契約を、純ドメインで固定する。
///
/// 壊れると何が起きるか。セグメント（隣接する同キーの連）は配列から導出するだけなので、不変条件が
/// 1 経路でも破れると、同じ worktree のタブが 2 本のセグメントに割れて色バーが二重に立ち、
/// セグメント内に閉じているはずの並び替えが別 worktree のタブを巻き込む。挿入位置が「同キー連の
/// 右端」からずれると、⌘T で開いたタブが隣の worktree の連に紛れ込む。active の参照追従が外れれば
/// 挿入・並び替えの直後に別のタブへフォーカスが飛ぶ。
///
/// TerminalTab は window 未接続なら libghostty surface を生成しないため、`groupKey` を直接注入した
/// タブで配列ロジックだけを検証する（キーの導出そのものは `GitWorktreeRootTests` /
/// `TerminalTabTests+GroupKey` が持つ）。
final class SessionStoreTabGroupTests: OrbeTestCase {

  // MARK: - fixture

  /// 所属キー `key` のタブ。タイトルにもキーを置き、失敗メッセージで並びを読めるようにする。
  func tab(_ key: String) -> TerminalTab {
    let tab = TerminalTab(cwd: "/tmp")
    tab.groupKey = key
    tab.explicitTitle = key
    return tab
  }

  /// キー列どおりのタブを持つ workspace。
  func workspace(_ keys: [String], active: Int = 0) -> Workspace {
    let ws = Workspace(name: "ws", rootPath: "/tmp")
    ws.tabs = keys.map(tab)
    ws.active = active
    return ws
  }

  /// キー列どおりのタブを持つアクティブ workspace 1 つだけの store。
  func makeStore(_ keys: [String], active: Int = 0) -> SessionStore {
    SessionStore(workspaces: [workspace(keys, active: active)], activeWorkspace: 0)
  }

  func keys(_ ws: Workspace) -> [String] { ws.tabs.map(\.groupKey) }

  func activeTab(_ ws: Workspace) -> TerminalTab { ws.tabs[ws.active] }

  // MARK: - 導出（セグメント）

  /// 隣接する同キーの連が 1 本のセグメントになり、キーが変わる境界で切れる。同キーでも離れていれば別の連。
  func testSegmentsSplitAtKeyBoundaries() {
    let tabs = ["a", "a", "b", "a", "c", "c", "c"].map(tab)
    XCTAssertEqual(
      SessionStore.segments(of: tabs), [0..<2, 2..<3, 3..<4, 4..<7],
      "連は隣接する同キーだけ。離れた同キーは別の連")
    XCTAssertEqual(SessionStore.segments(of: []), [], "0 タブは連なし")
  }

  /// `segment(containing:)` は index を含む連の範囲を返す。
  func testSegmentContainingIndexSpansItsRun() {
    let tabs = ["a", "b", "b", "b", "c"].map(tab)
    XCTAssertEqual(SessionStore.segment(containing: 2, in: tabs), 1..<4, "連の中央から両端まで伸びる")
    XCTAssertEqual(SessionStore.segment(containing: 0, in: tabs), 0..<1, "単独タブは自分だけ")
  }

  // MARK: - 復元時の正規化（load）

  /// 非隣接の同キー（旧ファイルからの復元）は初出順で連へ寄せられ、active は同じタブを指し続ける。
  func testLoadGroupsNonAdjacentTabsStablyAndKeepsActiveTab() {
    let ws = workspace(["a", "b", "a", "c", "b"], active: 2)
    let viewed = activeTab(ws)
    let store = SessionStore(workspaces: [], activeWorkspace: 0)

    store.load(workspaces: [ws], activeWorkspace: 0)

    XCTAssertEqual(keys(ws), ["a", "a", "b", "b", "c"], "初出順で連へ寄せる（安定分割）")
    XCTAssertTrue(activeTab(ws) === viewed, "active は正規化前と同じタブを指す")
    XCTAssertEqual(ws.active, 1, "そのタブの新しい index")
  }

  /// 既に隣接している配列は順序を変えない（正規化は不変条件が破れているときだけ効く）。
  func testLoadLeavesAlreadyGroupedOrderUntouched() {
    let ws = workspace(["b", "b", "a", "c"])
    let before = ws.tabs
    let store = SessionStore(workspaces: [], activeWorkspace: 0)

    store.load(workspaces: [ws], activeWorkspace: 0)

    XCTAssertTrue(ws.tabs.elementsEqual(before, by: ===), "隣接済みならそのまま")
  }

  // MARK: - 新規タブ（insertTab）

  /// 同キーの連があればその右端へ挿さり（配列末尾ではない）、実挿入 index が返る。
  func testInsertTabLandsAtRightEndOfItsSegment() {
    let store = makeStore(["a", "a", "b"])
    let new = tab("a")

    XCTAssertEqual(store.insertTab(new, intoWorkspaceAt: 0), 2, "a の連の右端 = index 2")
    XCTAssertEqual(keys(store.current), ["a", "a", "a", "b"])
    XCTAssertTrue(store.current.tabs[2] === new)
  }

  /// 同キーが無ければ末尾へ（新しい worktree は右端に生える）。
  func testInsertTabWithoutPeersAppends() {
    let store = makeStore(["a", "b"])

    XCTAssertEqual(store.insertTab(tab("c"), intoWorkspaceAt: 0), 2, "末尾")
    XCTAssertEqual(keys(store.current), ["a", "b", "c"])
  }

  /// アクティブ workspace では、挿入で index がずれても active は挿入前と同じタブを指し続ける
  /// （呼び出し側が直後に select する前提に寄りかからない）。
  func testInsertTabIntoActiveWorkspaceKeepsActiveOnSameTab() {
    let store = makeStore(["a", "b", "b"], active: 1)
    let viewed = activeTab(store.current)

    _ = store.insertTab(tab("a"), intoWorkspaceAt: 0)  // active(1) より前へ挿さる

    XCTAssertTrue(activeTab(store.current) === viewed, "active は挿入前と同じタブ")
    XCTAssertEqual(store.current.active, 2, "index は 1 つ繰り下がる")
  }

  /// 背景 workspace では挿したタブが active になる（制御 API の spawn がそのタブを見せる準備）。
  /// 初期 active は挿入先（index 1）と別にしておく——同じだと active を触らない実装でも緑になる。
  func testInsertTabIntoBackgroundWorkspaceActivatesInsertedTab() {
    let background = workspace(["a", "b"], active: 0)
    let store = SessionStore(
      workspaces: [workspace(["x"]), background], activeWorkspace: 0)
    let new = tab("a")

    XCTAssertEqual(store.insertTab(new, intoWorkspaceAt: 1), 1, "a の連の右端")
    XCTAssertTrue(activeTab(background) === new, "背景 workspace の active は挿したタブ")
  }

  // MARK: - 復元（insertRestoredTab）

  /// 復元した休眠チケットは同キーの連の右端へ入り、選択は挿す前と同じタブを指し続ける。
  /// 背景 workspace でも active を挿したタブへ動かさない（復元は見せる先を変えない）。
  func testRestoredTabJoinsItsSegmentWithoutMovingSelection() {
    let store = makeStore(["a", "b", "b"], active: 1)
    let before = activeTab(store.current)

    XCTAssertEqual(store.insertRestoredTab(tab("a"), intoWorkspaceAt: 0), 1, "a の連の右端")
    XCTAssertEqual(keys(store.current), ["a", "a", "b", "b"])
    XCTAssertTrue(activeTab(store.current) === before, "選択は同じタブのまま（index は 2 へ）")

    let background = workspace(["a"], active: 0)
    let two = SessionStore(workspaces: [workspace(["x"]), background], activeWorkspace: 0)
    XCTAssertEqual(two.insertRestoredTab(tab("z"), intoWorkspaceAt: 1), 1, "同キーが無ければ末尾")
    XCTAssertEqual(background.active, 0, "背景 workspace の active は動かない")
  }
}
