import XCTest

@testable import Orbe

/// 閉じたエージェントタブの開き直しスタック（⇧⌘T）の純ドメイン契約を固定する。
///
/// 観測可能な契約は「積むのは人のジェスチャで閉じたエージェントタブだけ」「閉じた時の index と復元単位が
/// 残る」「復元単位はタブ丸ごと（同居する素のシェルペインも分割ツリーごと）」「LIFO・workspace ごとに
/// 独立・上限 10」「挿入位置のクランプ」。
/// TerminalController は window 未接続なら libghostty surface を生成しないため、ここでは純ロジックとして
/// 検証できる（GhosttyKit ランタイムは起動しない）。スタックのエントリは明示タイトルで区別する
/// （`tabState().explicitTitle` に載る）。
final class SessionStoreClosedAgentTabsTests: XCTestCase {

  /// resume を必ず解決する（復元後の葉に agent が残り、snapshot に agent が載る）。
  private let resume: TerminalController.ResumeSpawn = { session in
    ("\(session.command) --resume \(session.sessionId)", [:])
  }

  /// エージェントペイン 1 枚のタブ。明示タイトルで区別できる。
  private func agentTab(_ title: String) -> TerminalController {
    tab(title, tree: .leaf(cwd: nil, agent: AgentSession(command: "claude", sessionId: title)))
  }

  /// エージェントを持たない素のシェルタブ。
  private func shellTab(_ title: String) -> TerminalController {
    tab(title, tree: .leaf(cwd: nil, agent: nil))
  }

  private func tab(_ title: String, tree: PaneNode) -> TerminalController {
    let tc = TerminalController(restoring: tree, resumeSpawn: resume)
    tc.explicitTitle = title
    return tc
  }

  /// エージェントタブだけを並べた workspace を組む。
  private func makeWorkspace(_ name: String, agents titles: [String]) -> Workspace {
    let ws = Workspace(name: name, rootPath: "/tmp")
    ws.tabs = titles.map(agentTab)
    return ws
  }

  /// 1 タブだけ持つ workspace を任意のツリーで組む。
  private func makeWorkspace(_ name: String, title: String, tree: PaneNode) -> Workspace {
    let ws = Workspace(name: name, rootPath: "/tmp")
    ws.tabs = [tab(title, tree: tree)]
    return ws
  }

  // MARK: - 積む条件（発火源 × エージェントの有無）

  /// 人のジェスチャ（タブ行の中クリック・⌘W）で閉じたエージェントタブは復元単位ごと積まれる。
  func testGestureCloseOfAgentTabIsPushedWithRestoreUnit() {
    let ws = makeWorkspace("ws", agents: ["a"])
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    _ = store.removeTab(ws.tabs[0], origin: .gesture)

    let closed = store.popClosedAgentTab()
    XCTAssertEqual(closed?.state.explicitTitle, "a", "閉じたタブの復元単位が積まれる")
    XCTAssertEqual(
      closed?.state.tree, .leaf(cwd: nil, agent: AgentSession(command: "claude", sessionId: "a")),
      "エージェントセッションごと復元単位に載る")
  }

  /// エージェントペインを持たない素のシェルタブは、人のジェスチャで閉じても積まない。
  func testGestureCloseOfPlainShellTabIsNotPushed() {
    let ws = makeWorkspace("ws", title: "plain", tree: .leaf(cwd: "/work", agent: nil))
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    _ = store.removeTab(ws.tabs[0], origin: .gesture)

    XCTAssertNil(store.popClosedAgentTab(), "素のシェルタブは積まない（⇧⌘T は無反応）")
  }

  /// 分割の中に素のシェルペインが混ざっていても、エージェントペインが 1 枚あれば積む。
  /// 戻す単位はタブ丸ごと——同居していた素のシェルペインも、分割の向き・比・cwd ごとそのまま戻る。
  func testAgentTabSplitWithPlainShellIsPushedWholeTree() {
    let tree: PaneNode = .split(
      vertical: true, ratio: 0.4,
      first: .leaf(cwd: "/work/api", agent: AgentSession(command: "claude", sessionId: "s1")),
      second: .leaf(cwd: "/work/web", agent: nil))
    let ws = makeWorkspace("ws", title: "mixed", tree: tree)
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    _ = store.removeTab(ws.tabs[0], origin: .gesture)

    XCTAssertEqual(
      store.popClosedAgentTab()?.state.tree, tree,
      "分割ツリー・分割比・cwd ごと、素のシェルペインも含めて丸ごと積む")
  }

  /// エージェントが 1 枚も無い分割タブは、ペインが何枚あっても積まない。
  func testPlainShellSplitIsNotPushed() {
    let tree: PaneNode = .split(
      vertical: false, ratio: 0.5,
      first: .leaf(cwd: "/work/a", agent: nil), second: .leaf(cwd: "/work/b", agent: nil))
    let ws = makeWorkspace("ws", title: "plainSplit", tree: tree)
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    _ = store.removeTab(ws.tabs[0], origin: .gesture)

    XCTAssertNil(store.popClosedAgentTab(), "素のシェルだけの分割タブも積まない")
  }

  /// シェル exit・エージェント終了（.process）と制御 API（.controlAPI）では、エージェントタブでも積まない。
  func testNonGestureCloseIsNotPushed() {
    for origin in [TabCloseOrigin.process, .controlAPI] {
      let ws = makeWorkspace("ws", agents: ["a"])
      let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

      _ = store.removeTab(ws.tabs[0], origin: origin)

      XCTAssertNil(store.popClosedAgentTab(), "\(origin) で落ちたタブは積まない（⇧⌘T は無反応）")
    }
  }

  /// 発火源の分類（人が自分の意思で畳んだのは gesture だけ）。
  func testOnlyGestureIsHumanGesture() {
    XCTAssertTrue(TabCloseOrigin.gesture.isHumanGesture, "タブ行の中クリック・⌘W は人のジェスチャ")
    XCTAssertFalse(TabCloseOrigin.process.isHumanGesture, "シェル exit・エージェント終了は外から落ちた閉鎖")
    XCTAssertFalse(TabCloseOrigin.controlAPI.isHumanGesture, "制御 API は経路を問わず人のジェスチャではない")
  }

  // MARK: - 閉じた位置の記録

  /// 先頭・中間・末尾のどこで閉じても、閉じた時点の index がそのまま残る。
  func testClosedIndexRecordsPositionAtCloseTime() {
    let titles = ["a", "b", "c"]
    for position in titles.indices {
      let ws = makeWorkspace("ws", agents: titles)
      let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

      _ = store.removeTab(ws.tabs[position], origin: .gesture)

      let closed = store.popClosedAgentTab()
      XCTAssertEqual(closed?.index, position, "閉じた時の index を記録する")
      XCTAssertEqual(closed?.state.explicitTitle, titles[position], "index と復元単位が同じタブを指す")
    }
  }

  /// 積まないタブ（素のシェル）を挟んでも、記録される index は閉じた時点の実位置。
  func testSkippedPlainTabDoesNotShiftRecordedIndex() {
    let ws = makeWorkspace("ws", agents: ["agent"])
    ws.tabs.insert(shellTab("plain"), at: 0)
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    _ = store.removeTab(ws.tabs[0], origin: .gesture)  // plain（積まれない）
    _ = store.removeTab(ws.tabs[0], origin: .gesture)  // agent（詰まって index 0）

    let closed = store.popClosedAgentTab()
    XCTAssertEqual(closed?.state.explicitTitle, "agent", "積まれたのはエージェントタブだけ")
    XCTAssertEqual(closed?.index, 0, "閉じた時点の実 index（詰まった後の 0）を記録する")
  }

  // MARK: - LIFO・上限・workspace ごとの独立

  /// 直近に閉じたものから戻る（LIFO）。空なら nil＝呼び出し側は無反応。
  func testPopReturnsMostRecentlyClosedAndNilWhenEmpty() {
    let ws = makeWorkspace("ws", agents: ["a", "b"])
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)
    XCTAssertNil(store.popClosedAgentTab(), "何も閉じていなければ nil")

    _ = store.removeTab(ws.tabs[0], origin: .gesture)  // a
    _ = store.removeTab(ws.tabs[0], origin: .gesture)  // b（a を外した後の先頭）

    XCTAssertEqual(store.popClosedAgentTab()?.state.explicitTitle, "b", "直近に閉じた b が先に戻る")
    XCTAssertEqual(store.popClosedAgentTab()?.state.explicitTitle, "a", "次に a が戻る")
    XCTAssertNil(store.popClosedAgentTab(), "汲み尽くしたら nil")
  }

  /// 上限 10。11 件目以降を積むと最古から落ち、残るのは新しい 10 件。
  func testStackKeepsNewestTenAndDropsOldest() {
    let titles = (0..<12).map { "t\($0)" }
    let ws = makeWorkspace("ws", agents: titles)
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    for _ in titles { _ = store.removeTab(ws.tabs[0], origin: .gesture) }

    var popped: [String] = []
    while let closed = store.popClosedAgentTab() { popped.append(closed.state.explicitTitle ?? "") }
    XCTAssertEqual(
      popped, Array(titles.dropFirst(2).reversed()),
      "最古 2 件は捨てられ、新しい 10 件が LIFO で戻る")
  }

  /// スタックは workspace ごとに独立（A で閉じたタブが B で復活しない）。
  func testStacksAreIndependentPerWorkspace() {
    let alpha = makeWorkspace("alpha", agents: ["a"])
    let beta = makeWorkspace("beta", agents: ["b"])
    let store = SessionStore(workspaces: [alpha, beta], activeWorkspace: 0)

    _ = store.removeTab(alpha.tabs[0], origin: .gesture)

    store.setActiveWorkspace(1)
    XCTAssertNil(store.popClosedAgentTab(), "A で閉じたタブは B では戻せない")
    store.setActiveWorkspace(0)
    XCTAssertEqual(
      store.popClosedAgentTab()?.state.explicitTitle, "a", "A へ戻れば A のスタックから戻せる")
  }

  // MARK: - 挿入位置のクランプ

  /// 指定した index にタブが挿さり、後続が 1 つ後ろへ押し出される。
  /// 中間を叩くのが要点——先頭・末尾だけだと `insert(at: 0)` や `append` の決め打ちと区別できず、
  /// 戻り値が合っているだけで「閉じた位置へ戻す」が壊れていても気づけない。
  func testInsertLandsAtGivenIndexAndShiftsFollowers() {
    let ws = makeWorkspace("ws", agents: ["a", "b", "c"])
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    XCTAssertEqual(store.insertTabIntoActive(agentTab("mid"), at: 1), 1, "戻り値は実挿入 index")

    XCTAssertEqual(
      ws.tabs.map(\.explicitTitle), ["a", "mid", "b", "c"], "指定 index へ挿さり後続が押し出される")
  }

  /// 有効範囲外の index は 0…count へクランプし、戻り値は実挿入 index。クランプ先へ実際に挿さる。
  func testInsertClampsToValidRangeAndReturnsActualIndex() {
    let ws = makeWorkspace("ws", agents: ["a", "b"])
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    XCTAssertEqual(store.insertTabIntoActive(agentTab("head"), at: -3), 0, "負値は先頭へクランプ")
    XCTAssertEqual(store.insertTabIntoActive(agentTab("tail"), at: 99), 3, "count 超は末尾へクランプ")
    XCTAssertEqual(
      ws.tabs.map(\.explicitTitle), ["head", "a", "b", "tail"], "クランプ先の位置へ実際に挿さる")
  }

  /// 0タブ（休眠）workspace への挿入は index 0 に着地し、active がそのタブを指す。
  func testInsertIntoEmptyWorkspaceLandsAtZero() {
    let ws = makeWorkspace("ws", agents: [])
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    XCTAssertEqual(store.insertTabIntoActive(agentTab("only"), at: 5), 0, "0タブでは index 0 へ")
    XCTAssertEqual(ws.active, 0, "active は唯一のタブを指す（範囲外に飛ばない）")
  }

  /// 挿入位置が現 active より前なら、active は挿入前と同じタブを指し続ける。
  func testInsertBeforeActiveKeepsActiveOnSameTab() {
    let ws = makeWorkspace("ws", agents: ["a", "b"])
    ws.active = 1
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    XCTAssertEqual(store.insertTabIntoActive(agentTab("head"), at: 0), 0)
    XCTAssertEqual(ws.tabs[ws.active].explicitTitle, "b", "active は挿入前と同じタブを指す")
  }

  /// 挿入位置が現 active と同値のときも同じタブを指し続ける（`dest <= active` の境界）。
  /// ここを `<` に緩めると、復元したタブが割り込んだ分だけ選択が 1 つ手前へずれる。
  func testInsertAtActiveIndexKeepsActiveOnSameTab() {
    let ws = makeWorkspace("ws", agents: ["a", "b"])
    ws.active = 1
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    XCTAssertEqual(store.insertTabIntoActive(agentTab("mid"), at: 1), 1)

    XCTAssertEqual(ws.tabs.map(\.explicitTitle), ["a", "mid", "b"])
    XCTAssertEqual(ws.tabs[ws.active].explicitTitle, "b", "active は挿入前と同じタブを指す")
  }
}
