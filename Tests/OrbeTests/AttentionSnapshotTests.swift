import XCTest

@testable import Orbe

/// Attention snapshot builder（`AttentionSnapshot`）の契約を固定する。
/// 対象は activated タブのライブペインのみ・waiting/done/working のみ・stateChangedAt 降順。
/// あわせて `Workspace.agentCounts()` / `AgentRollup.grandTotal(of:)` が同じ母集合を数えることも固定する。
@MainActor
final class AttentionSnapshotTests: OrbeTestCase {

  /// 1 タブ 1 ペインの workspace を組む。live はタブの正規遷移で作る。
  private func workspace(name: String, activated: Bool = true) -> Workspace {
    let ws = Workspace(name: name, rootPath: "/tmp/\(name)")
    let tab = TerminalController(initialCwd: "/tmp/\(name)")
    ws.tabs.append(tab)
    if activated { tab.recordMaterializationStarted() }
    return ws
  }

  /// workspace の先頭ペインへ状態を立てる（nil は報告なしへ戻す）。
  private func setState(
    _ ws: Workspace, tab: Int = 0, state: String?, message: String? = nil, at: Date? = nil
  ) {
    let pane = ws.tabs[tab].controlAllPanes()[0]
    guard let state else {
      pane.agentSlot = .none
      return
    }
    setReportedState(pane, state, at: at ?? Date(), message: message.map { AgentMessage(text: $0) })
  }

  // MARK: builder

  /// 休眠（未 activate）workspace のペインは出ない。
  func testDormantWorkspaceExcluded() {
    let ws = workspace(name: "dormant", activated: false)
    setState(ws, state: "waiting", at: Date())
    XCTAssertTrue(AttentionSnapshot.rows(of: [ws]).isEmpty)
    XCTAssertTrue(ws.agentCounts().isEmpty)
    XCTAssertTrue(AgentRollup.grandTotal(of: [ws]).isEmpty)
  }

  /// workspace 内がlive/dormant混在でも、workspace全体の activated ではなく
  /// 発信元タブの現在状態で母集合を決める。
  func testMixedWorkspaceIncludesOnlyActivatedTab() {
    let ws = workspace(name: "mixed")
    let dormant = TerminalController(initialCwd: "/tmp/mixed")
    ws.tabs.append(dormant)
    setState(ws, tab: 0, state: "waiting", at: Date())
    setState(ws, tab: 1, state: "done", at: Date().addingTimeInterval(1))

    XCTAssertTrue(ws.activated, "live sibling があれば workspace は activated")
    XCTAssertFalse(dormant.activated)
    XCTAssertEqual(AttentionSnapshot.rows(of: [ws]).map(\.state), ["waiting"])
    XCTAssertEqual(ws.agentCounts(), ["waiting": 1])
    XCTAssertEqual(AgentRollup.grandTotal(of: [ws]), ["waiting": 1])
  }

  /// 現在の active workspace に限らず、activated タブは workspace を横断して集計する。
  func testActivatedTabsAreCollectedAcrossWorkspaces() {
    let foreground = workspace(name: "foreground")
    let background = workspace(name: "background")
    setState(foreground, state: "waiting", at: Date())
    setState(background, state: "done", at: Date().addingTimeInterval(1))

    let rows = AttentionSnapshot.rows(of: [foreground, background])
    XCTAssertEqual(Set(rows.map(\.workspaceName)), ["foreground", "background"])
    XCTAssertEqual(
      AgentRollup.grandTotal(of: [foreground, background]), ["waiting": 1, "done": 1])
  }

  /// idle・nil（状態なし）は出ない。waiting/done/working だけが出る。
  func testIdleAndNilExcluded() {
    let idle = workspace(name: "idle")
    setState(idle, state: "idle", at: Date())
    let none = workspace(name: "none")
    setState(none, state: nil)
    let waiting = workspace(name: "w")
    setState(waiting, state: "waiting", at: Date())
    let unknown = workspace(name: "unknown")
    setState(unknown, state: "error", at: Date())
    let rows = AttentionSnapshot.rows(of: [idle, none, unknown, waiting])
    XCTAssertEqual(rows.map(\.workspaceName), ["w"])
    XCTAssertEqual(
      AgentRollup.grandTotal(of: [idle, none, unknown, waiting]),
      ["idle": 1, "waiting": 1], "idle は live 集計だけ、nil/unknown は両面から除外")
  }

  func testActivatedAttentionStatesMatchLiveRollupStateNames() {
    let waiting = workspace(name: "waiting")
    let done = workspace(name: "done")
    let working = workspace(name: "working")
    setState(waiting, state: "waiting", at: Date())
    setState(done, state: "done", at: Date())
    setState(working, state: "working", at: Date())

    let workspaces = [waiting, done, working]
    XCTAssertEqual(
      Set(AttentionSnapshot.rows(of: workspaces).map(\.state)), ["waiting", "done", "working"])
    XCTAssertEqual(AgentRollup.grandTotal(of: workspaces), ["waiting": 1, "done": 1, "working": 1])
  }

  /// stateChangedAt 降順で並び、同時刻は paneId 降順で安定化する。
  func testSortNewestFirstWithPaneIdTieBreak() throws {
    let base = Date()
    let old = workspace(name: "old")
    setState(old, state: "done", at: base.addingTimeInterval(-100))
    let newer = workspace(name: "newer")
    setState(newer, state: "waiting", at: base)
    let tieA = workspace(name: "tieA")
    setState(tieA, state: "working", at: base.addingTimeInterval(-50))
    let tieB = workspace(name: "tieB")
    setState(tieB, state: "working", at: base.addingTimeInterval(-50))
    let rows = AttentionSnapshot.rows(of: [old, tieA, tieB, newer])
    XCTAssertEqual(rows.map(\.workspaceName), ["newer", "tieB", "tieA", "old"])
    // 同時刻の 2 枚は paneId 降順（tieB のペインが後に採番され id が大きい）。
    let tieBRow = try XCTUnwrap(rows.first { $0.workspaceName == "tieB" })
    let tieARow = try XCTUnwrap(rows.first { $0.workspaceName == "tieA" })
    XCTAssertGreaterThan(tieBRow.paneId, tieARow.paneId)
  }

  /// working 行は message を持たない（ライブ進行は配管しない＝builder が nil に落とす）。
  func testWorkingMessageSuppressed() throws {
    let ws = workspace(name: "w")
    setState(ws, state: "working", message: "stale な文言", at: Date())
    let row = try XCTUnwrap(AttentionSnapshot.rows(of: [ws]).first)
    XCTAssertNil(row.message)
  }

  /// waiting / done は message を保つ。
  func testWaitingAndDoneKeepMessage() {
    let w = workspace(name: "w")
    setState(w, state: "waiting", message: "質問文", at: Date())
    let d = workspace(name: "d")
    setState(d, state: "done", message: "最終応答", at: Date().addingTimeInterval(-1))
    let rows = AttentionSnapshot.rows(of: [w, d])
    XCTAssertEqual(rows.map(\.message), ["質問文", "最終応答"])
  }

  // MARK: メニューバー派生

  /// 一覧行・件数は waiting+done のみ（working は数えない）。
  func testListRowsAndCountExcludeWorking() {
    let base = Date()
    let w = workspace(name: "w")
    setState(w, state: "waiting", at: base)
    let d = workspace(name: "d")
    setState(d, state: "done", at: base.addingTimeInterval(-1))
    let g = workspace(name: "g")
    setState(g, state: "working", at: base.addingTimeInterval(-2))
    let rows = AttentionSnapshot.rows(of: [w, d, g])
    XCTAssertEqual(AttentionSnapshot.listRows(rows).map(\.workspaceName), ["w", "d"])
    XCTAssertEqual(AttentionSnapshot.listRows(rows).count, 2)
  }

  /// working 集約の素材は件数（ペイン数）＋WS 名（重複排除・**出現順**）。working 0 件は nil。
  /// 名は辞書順と出現順が食い違う組（zeta が先・alpha が後）で採る——`ws1, ws2` のように
  /// 両者が一致する組だと、実装が誤って sort しても通ってしまう。
  func testWorkingSummaryDeduplicatesWorkspacesInAppearanceOrder() {
    let base = Date()
    let a = Workspace(name: "zeta", rootPath: "/tmp/zeta")
    a.tabs.append(TerminalController(initialCwd: "/tmp/zeta"))
    a.tabs.append(TerminalController(initialCwd: "/tmp/zeta"))
    a.tabs.forEach { $0.recordMaterializationStarted() }
    setReportedState(a.tabs[0].controlAllPanes()[0], "working", at: base)
    setReportedState(a.tabs[1].controlAllPanes()[0], "working", at: base.addingTimeInterval(-1))
    let b = workspace(name: "alpha")
    setState(b, state: "working", at: base.addingTimeInterval(-2))
    let rows = AttentionSnapshot.rows(of: [a, b])
    let summary = AttentionSnapshot.workingSummary(rows)
    XCTAssertEqual(summary?.count, 3, "件数は WS 数ではなく working ペイン数")
    XCTAssertEqual(summary?.names, ["zeta", "alpha"], "重複排除して出現順（辞書順に直さない）")

    let waitingOnly = workspace(name: "w")
    setState(waitingOnly, state: "waiting", at: base)
    XCTAssertNil(AttentionSnapshot.workingSummary(AttentionSnapshot.rows(of: [waitingOnly])))
  }

  // MARK: elapsedLabel

  /// 表示単位の境界（s → m → h → d）。負は 0s に丸める。
  func testElapsedLabelBoundaries() {
    let now = Date()
    func label(_ seconds: TimeInterval) -> String {
      AttentionSnapshot.elapsedLabel(from: now.addingTimeInterval(-seconds), to: now)
    }
    XCTAssertEqual(label(-10), "0s")
    XCTAssertEqual(label(0), "0s")
    XCTAssertEqual(label(45), "45s")
    XCTAssertEqual(label(59), "59s")
    XCTAssertEqual(label(60), "1m")
    XCTAssertEqual(label(59 * 60), "59m")
    XCTAssertEqual(label(60 * 60), "1h")
    XCTAssertEqual(label(23 * 60 * 60), "23h")
    XCTAssertEqual(label(24 * 60 * 60), "1d")
    XCTAssertEqual(label(3 * 24 * 60 * 60), "3d")
  }
}
