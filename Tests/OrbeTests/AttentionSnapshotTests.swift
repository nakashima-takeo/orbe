import XCTest

@testable import Orbe

/// Attention snapshot builder（`AttentionSnapshot`）の契約を固定する。
/// 対象はライブペインのみ（activated な WS）・waiting/done/working のみ・stateChangedAt 降順。
@MainActor
final class AttentionSnapshotTests: XCTestCase {

  /// 1 タブ 1 ペインの workspace を組む（活性は引数）。
  private func workspace(name: String, activated: Bool = true) -> Workspace {
    let ws = Workspace(name: name, rootPath: "/tmp/\(name)")
    ws.activated = activated
    ws.tabs.append(TerminalController(initialCwd: "/tmp/\(name)"))
    return ws
  }

  /// workspace の先頭ペインへ状態を立てる。
  private func setState(
    _ ws: Workspace, tab: Int = 0, state: String?, message: String? = nil, at: Date? = nil
  ) {
    let pane = ws.tabs[tab].controlAllPanes()[0]
    pane.agentState = state
    pane.agentMessage = message
    pane.agentStateChangedAt = at
  }

  // MARK: builder

  /// 休眠（未 activate）workspace のペインは出ない。
  func testDormantWorkspaceExcluded() {
    let ws = workspace(name: "dormant", activated: false)
    setState(ws, state: "waiting", at: Date())
    XCTAssertTrue(AttentionSnapshot.rows(of: [ws]).isEmpty)
  }

  /// idle・nil（状態なし）は出ない。waiting/done/working だけが出る。
  func testIdleAndNilExcluded() {
    let idle = workspace(name: "idle")
    setState(idle, state: "idle", at: Date())
    let none = workspace(name: "none")
    setState(none, state: nil)
    let waiting = workspace(name: "w")
    setState(waiting, state: "waiting", at: Date())
    let rows = AttentionSnapshot.rows(of: [idle, none, waiting])
    XCTAssertEqual(rows.map(\.workspaceName), ["w"])
  }

  /// stateChangedAt 降順で並び、同時刻は paneId 降順で安定化する。
  func testSortNewestFirstWithPaneIdTieBreak() {
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
    XCTAssertEqual(rows.map(\.workspaceName).first, "newer")
    XCTAssertEqual(rows.map(\.workspaceName).last, "old")
    // 同時刻の 2 枚は paneId 降順（tieB のペインが後に採番され id が大きい）。
    let tiePair = Array(rows[1...2])
    XCTAssertEqual(tiePair.map(\.workspaceName), ["tieB", "tieA"])
    XCTAssertGreaterThan(tiePair[0].paneId, tiePair[1].paneId)
  }

  /// working 行は message を持たない（ライブ進行は配管しない＝builder が nil に落とす）。
  func testWorkingMessageSuppressed() {
    let ws = workspace(name: "w")
    setState(ws, state: "working", message: "stale な文言", at: Date())
    XCTAssertNil(AttentionSnapshot.rows(of: [ws])[0].message)
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

  /// working 集約ラベルは件数＋WS 名（重複排除・出現順）。working 0 件は nil。
  func testWorkingLabelDeduplicatesWorkspaces() {
    let base = Date()
    let a = Workspace(name: "ws1", rootPath: "/tmp/ws1")
    a.activated = true
    a.tabs.append(TerminalController(initialCwd: "/tmp/ws1"))
    a.tabs.append(TerminalController(initialCwd: "/tmp/ws1"))
    a.tabs[0].controlAllPanes()[0].agentState = "working"
    a.tabs[0].controlAllPanes()[0].agentStateChangedAt = base
    a.tabs[1].controlAllPanes()[0].agentState = "working"
    a.tabs[1].controlAllPanes()[0].agentStateChangedAt = base.addingTimeInterval(-1)
    let b = workspace(name: "ws2")
    setState(b, state: "working", at: base.addingTimeInterval(-2))
    let rows = AttentionSnapshot.rows(of: [a, b])
    XCTAssertEqual(AttentionSnapshot.workingLabel(rows), "3 working — ws1, ws2")

    let waitingOnly = workspace(name: "w")
    setState(waitingOnly, state: "waiting", at: base)
    XCTAssertNil(AttentionSnapshot.workingLabel(AttentionSnapshot.rows(of: [waitingOnly])))
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
