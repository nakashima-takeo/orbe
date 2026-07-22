import AppKit
import XCTest

@testable import Orbe

/// 分割ツリー（host 所有の NSSplitView レイアウト）の不変条件を守る。
/// window に未接続なら SurfaceView は libghostty surface を生成しない
/// （生成は viewDidMoveToWindow 依存）ため、libghostty を起動せずトポロジーだけ検証できる。
///
/// 各ペインは SurfaceScrollView（ネイティブスクロールバー付き）でラップされてツリーに置かれる。
/// よって分割の arrangedSubview / rootContainer 直下の葉は SurfaceScrollView で、
/// その中の SurfaceView は `.surfaceView` で取り出す。
final class TerminalControllerTests: XCTestCase {
  private func rootSplit(_ tc: TerminalController) -> NSSplitView? {
    tc.rootContainer.subviews.first as? NSSplitView
  }

  /// 葉ラップ（SurfaceScrollView）から SurfaceView を取り出す。
  private func pane(_ v: NSView) -> SurfaceView {
    (v as! SurfaceScrollView).surfaceView
  }

  func testInitialSinglePane() {
    let tc = TerminalController()
    XCTAssertEqual(tc.rootContainer.subviews.count, 1)
    XCTAssertTrue(tc.rootContainer.subviews.first is SurfaceScrollView)
    XCTAssertNotNil(tc.focusedPane)
  }

  func testSplitOrientation() {
    let h = TerminalController()
    h.split(.horizontal)  // 左右分割 = 縦の境界線 → isVertical = true
    XCTAssertEqual(rootSplit(h)?.isVertical, true)
    XCTAssertEqual(rootSplit(h)?.arrangedSubviews.count, 2)

    let v = TerminalController()
    v.split(.vertical)  // 上下分割 = 横の境界線 → isVertical = false
    XCTAssertEqual(rootSplit(v)?.isVertical, false)
    XCTAssertEqual(rootSplit(v)?.arrangedSubviews.count, 2)
  }

  func testNestedSplitOnFocusedPane() {
    let tc = TerminalController()
    let a = tc.focusedPane!
    tc.split(.horizontal)  // root: split1[a, b]
    let split1 = rootSplit(tc)!
    let b = pane(split1.arrangedSubviews[1])

    tc.focusedPaneChanged(b)  // フォーカスを b へ移す
    tc.split(.vertical)  // b を分割 → split1: [a, split2[b, c]]

    XCTAssertTrue(pane(split1.arrangedSubviews[0]) === a)
    let split2 = split1.arrangedSubviews[1] as? NSSplitView
    XCTAssertNotNil(split2)
    XCTAssertEqual(split2?.arrangedSubviews.count, 2)
    XCTAssertTrue(pane(split2!.arrangedSubviews[0]) === b)
  }

  func testClosePaneCollapsesSplitAndPromotesSibling() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    let a = pane(split.arrangedSubviews[0])
    let b = pane(split.arrangedSubviews[1])

    tc.close(b)  // 残り 1 枚 → split を畳んで a を rootContainer 直下へ昇格

    XCTAssertEqual(tc.rootContainer.subviews.count, 1)
    XCTAssertTrue(pane(tc.rootContainer.subviews.first!) === a)
  }

  func testCloseLastPaneFiresOnEmpty() {
    let tc = TerminalController()
    let exp = expectation(description: "onEmpty fires")
    tc.onEmpty = { exp.fulfill() }
    tc.close(tc.focusedPane!)  // ルート唯一のペイン → このタブを閉じる通知（main へ async）
    wait(for: [exp], timeout: 1.0)
  }

  func testPreferredFocusPaneFollowsLastFocus() {
    let tc = TerminalController()
    let a = tc.focusedPane!
    XCTAssertTrue(tc.preferredFocusPane === a, "初期は最初のペイン")

    tc.split(.horizontal)
    let b = pane(rootSplit(tc)!.arrangedSubviews[1])
    tc.focusedPaneChanged(b)
    XCTAssertTrue(tc.preferredFocusPane === b, "最後にフォーカスしたペインを返す")
  }

  func testRequestWindowCommandForwardsToHandler() {
    let tc = TerminalController()
    var received: [TerminalController.WindowCommand] = []
    tc.onWindowCommand = { received.append($0) }
    tc.requestWindowCommand(.newTab)
    tc.requestWindowCommand(.switchWorkspace)
    XCTAssertEqual(received, [.newTab, .switchWorkspace])
  }

  func testPanePwdChangedFiresOnPwdChange() {
    let tc = TerminalController()
    var fired = 0
    tc.onPwdChange = { fired += 1 }
    tc.panePwdChanged()
    XCTAssertEqual(fired, 1)
  }

  func testPaneAgentStateChangedFiresOnAgentStateChange() {
    let tc = TerminalController()
    var fired = 0
    tc.onAgentStateChange = { fired += 1 }
    tc.paneAgentStateChanged()
    XCTAssertEqual(fired, 1)
  }

  // MARK: - aggregateAgentState

  func testAggregateNilWhenNoActiveState() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    pane(split.arrangedSubviews[0]).agentState = nil
    pane(split.arrangedSubviews[1]).agentState = "idle"
    XCTAssertNil(tc.aggregateAgentState(), "idle・nil のみならアイコン無し")
  }

  func testAggregatePicksWaitingOverWorking() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    let a = pane(split.arrangedSubviews[0])
    let b = pane(split.arrangedSubviews[1])
    a.agentState = "working"
    b.agentState = "waiting"
    XCTAssertEqual(tc.aggregateAgentState(), .waiting, "waiting > working")
  }

  // MARK: - consumeDoneState

  func testConsumeClearsAllDonePanesAcrossTab() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    let a = pane(split.arrangedSubviews[0])
    let b = pane(split.arrangedSubviews[1])
    a.agentState = "done"
    b.agentState = "done"

    tc.consumeDoneState()

    XCTAssertEqual(a.agentState, "idle", "done は idle(休止)へ")
    XCTAssertEqual(b.agentState, "idle", "done は idle(休止)へ")
    XCTAssertNil(tc.aggregateAgentState(), "idle はタブに出ない＝集約 done バッジが消える")
  }

  func testConsumeKeepsWaitingAndWorking() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    let a = pane(split.arrangedSubviews[0])
    let b = pane(split.arrangedSubviews[1])
    a.agentState = "waiting"
    b.agentState = "working"

    tc.consumeDoneState()

    XCTAssertEqual(a.agentState, "waiting", "waiting は消費しない")
    XCTAssertEqual(b.agentState, "working", "working は消費しない")
  }

  func testConsumePreservesAgentSessionForResume() {
    let tc = TerminalController()
    let a = tc.focusedPane!
    a.agentState = "done"
    a.agentCommand = "claude"
    a.agentSessionId = "sess-1"

    tc.consumeDoneState()

    XCTAssertEqual(a.agentState, "idle", "done は idle(休止)へ")
    XCTAssertEqual(a.agentCommand, "claude", "resume 用の command は保持")
    XCTAssertEqual(a.agentSessionId, "sess-1", "resume 用の sessionId は保持")
  }

  func testConsumeIsScopedToReceiverTab() {
    // ヘルパーはアクティブ表示タブにだけ consumeDoneState() を呼ぶ。
    // 消費は受け手タブに閉じ、別タブ（背景タブ）の done は残る。
    let active = TerminalController()
    let background = TerminalController()
    active.focusedPane!.agentState = "done"
    background.focusedPane!.agentState = "done"

    active.consumeDoneState()

    XCTAssertEqual(active.focusedPane!.agentState, "idle", "受け手タブの done は idle(休止)へ")
    XCTAssertEqual(background.focusedPane!.agentState, "done", "背景タブの done は残る")
  }

  func testConsumeOnNonDonePaneNoOp() {
    let tc = TerminalController()
    let a = tc.focusedPane!
    a.agentState = nil

    tc.consumeDoneState()

    XCTAssertNil(a.agentState)
    XCTAssertNil(tc.aggregateAgentState())
  }

  // MARK: - agentStateCounts（横断集計の per-tab 基盤）

  func testAgentStateCountsTalliesPerState() {
    let tc = TerminalController()
    let a = tc.focusedPane!
    tc.split(.horizontal)  // root: [a, b]
    let b = pane(rootSplit(tc)!.arrangedSubviews[1])
    tc.focusedPaneChanged(b)
    tc.split(.vertical)  // b を縦分割 → [a, [b, c]]
    let bSplit = rootSplit(tc)!.arrangedSubviews[1] as! NSSplitView
    let c = pane(bSplit.arrangedSubviews[1])

    a.agentState = "working"
    b.agentState = "waiting"
    c.agentState = "working"

    let counts = tc.agentStateCounts()
    XCTAssertEqual(counts["working"], 2, "working は 2 ペイン")
    XCTAssertEqual(counts["waiting"], 1, "waiting は 1 ペイン")
    XCTAssertNil(counts["done"])
  }

  func testAgentStateCountsTalliesIdleButNotNil() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    pane(split.arrangedSubviews[0]).agentState = "idle"
    pane(split.arrangedSubviews[1]).agentState = nil
    XCTAssertEqual(tc.agentStateCounts()["idle"], 1, "idle は横断集計に数える")
    XCTAssertEqual(tc.agentStateCounts().count, 1, "nil は数えない")
  }

  // MARK: - displayTitle の precedence（① explicitTitle ?? ② paneTitle ?? ③ derived）

  func testDisplayTitleExplicitWins() {
    let tc = TerminalController()
    tc.focusedPane!.paneTitle = "vim"
    tc.focusedPane!.initialCwd = "/Users/me/proj/src"
    tc.explicitTitle = "build"
    XCTAssertEqual(
      tc.displayTitle(workspaceRoot: "/Users/me/proj"), "build", "① explicitTitle が最優先")
  }

  func testDisplayTitleFallsBackToPaneTitle() {
    let tc = TerminalController()
    tc.focusedPane!.paneTitle = "vim"
    tc.focusedPane!.initialCwd = "/Users/me/proj/src"
    XCTAssertEqual(
      tc.displayTitle(workspaceRoot: "/Users/me/proj"), "vim", "明示なし → ② paneTitle(非空)")
  }

  func testDisplayTitleFallsBackToDerivedWhenPaneTitleEmpty() {
    let tc = TerminalController()
    tc.focusedPane!.initialCwd = "/Users/me/proj/src/app"
    XCTAssertEqual(
      tc.displayTitle(workspaceRoot: "/Users/me/proj"), "p/s/app",
      "明示なし・paneTitle 空 → ③ derived（圧縮アンカーは root の親＝先頭に root 名）")
  }

  func testDisplayTitleEmptyExplicitFallsThrough() {
    let tc = TerminalController()
    tc.focusedPane!.paneTitle = "vim"
    tc.explicitTitle = ""  // 空は採用しない（②③へ戻る）
    XCTAssertEqual(
      tc.displayTitle(workspaceRoot: nil), "vim", "空の explicitTitle は無視し ② へ")
  }

  func testDisplayTitleIgnoresPwdFallbackTitle() {
    // libghostty は明示タイトル未受信の間、生 pwd を paneTitle に入れる（OSC 7 フォールバック）。
    // paneTitle == currentPwd ならそれは pwd フォールバックなので②を飛ばし③で圧縮整形する。
    let tc = TerminalController()
    tc.focusedPane!.currentPwd = "/Users/me/proj/src/app"
    tc.focusedPane!.paneTitle = "/Users/me/proj/src/app"  // Ghostty の pwd フォールバックと同値
    XCTAssertEqual(
      tc.displayTitle(workspaceRoot: "/Users/me/proj"), "p/s/app",
      "paneTitle == currentPwd（pwd フォールバック）は ② にせず ③ で圧縮")
  }

  func testDisplayTitleKeepsAppTitleDifferingFromPwd() {
    // 本物のアプリタイトル（pwd と異なる）は②としてそのまま採用する。
    let tc = TerminalController()
    tc.focusedPane!.currentPwd = "/Users/me/proj/src/app"
    tc.focusedPane!.paneTitle = "vim"
    XCTAssertEqual(
      tc.displayTitle(workspaceRoot: "/Users/me/proj"), "vim",
      "paneTitle != currentPwd は本物のアプリタイトル → ②")
  }

  func testAggregatePicksWorkingOverDone() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    let a = pane(split.arrangedSubviews[0])
    let b = pane(split.arrangedSubviews[1])
    a.agentState = "done"
    b.agentState = "working"
    // working(b) が done(a) に勝つ（CLI 非依存）
    XCTAssertEqual(tc.aggregateAgentState(), .working)
  }
}
