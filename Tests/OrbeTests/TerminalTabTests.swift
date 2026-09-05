import AppKit
import XCTest

@testable import Orbe

/// タブ（surface 1 枚と「タブの状態」の所有者）の不変条件を守る。
/// window に未接続なら SurfaceView は libghostty surface を生成しない
/// （生成は viewDidMoveToWindow 依存）ため、libghostty を起動せず検証できる。
final class TerminalTabTests: OrbeTestCase {
  func testViewWrapsSingleSurface() {
    let tab = TerminalTab(cwd: "/tmp")
    XCTAssertTrue(tab.view.surfaceView === tab.surface)
    XCTAssertTrue(tab.surface.tab === tab, "surface は所属タブを知る（事実の通知先）")
    XCTAssertEqual(tab.surface.initialCwd, "/tmp")
  }

  /// 閉鎖要求は onClose を発火し、**発火源を判断せずそのまま素通しする**。
  /// 全ケースを回すのは、素通しがどれか 1 つへの決め打ちに化けるのを止めるため——化けても
  /// コンパイルは通り、「⌘W で閉じたタブが戻らない」か「shell exit まで積む」が静かに起きる。
  ///
  /// 発火は要求の中では起きない——⌘W の keyDown・シェル exit の libghostty コールバックの最中に
  /// 上位が surface を解放すると、戻った先が解放済みの view を触る。
  func testCloseFiresOnCloseCarryingOrigin() {
    for origin in [TabCloseOrigin.gesture, .process, .controlAPI] {
      let tab = TerminalTab(cwd: "/tmp")
      let exp = expectation(description: "onClose fires for \(origin)")
      var received: TabCloseOrigin?
      tab.onClose = {
        received = $0
        exp.fulfill()
      }
      tab.close(origin: origin)
      XCTAssertNil(received, "閉鎖要求の中では発火しない（要求元が戻ってから）")
      wait(for: [exp], timeout: 1.0)
      XCTAssertEqual(received, origin, "close の発火源をそのまま上位へ渡す")
    }
  }

  /// ⌘W（`.closeTab`）は人のジェスチャとして届く。キーから close までの唯一の分岐点で、
  /// ここが `.process` に化けると ⇧⌘T が主用途（⌘W で閉じた直後）で無反応になる。
  func testCloseTabChromeActionReportsGestureOrigin() {
    let tab = TerminalTab(cwd: "/tmp")
    let exp = expectation(description: "onClose fires")
    var received: TabCloseOrigin?
    tab.onClose = {
      received = $0
      exp.fulfill()
    }
    tab.surface.perform(.closeTab)  // ⌘W の届き先（Keybindings → SurfaceView.perform）
    wait(for: [exp], timeout: 1.0)
    XCTAssertEqual(received, .gesture, "⌘W は人のジェスチャとして届く")
  }

  func testRequestWindowCommandForwardsToHandler() {
    let tab = TerminalTab(cwd: "/tmp")
    var received: [WindowCommand] = []
    tab.onWindowCommand = { received.append($0) }
    tab.requestWindowCommand(.newTab)
    tab.requestWindowCommand(.switchWorkspace)
    XCTAssertEqual(received, [.newTab, .switchWorkspace])
  }

  /// 変化判定は値を持つ surface 側にある——同値の再代入は通知しない。
  func testPwdChangeForwardsOnlyOnRealChange() {
    let tab = TerminalTab(cwd: "/tmp")
    var fired = 0
    tab.onPwdChange = { fired += 1 }
    tab.surface.currentPwd = "/work"
    tab.surface.currentPwd = "/work"
    XCTAssertEqual(fired, 1)
    XCTAssertEqual(tab.cwd, "/work", "実効 cwd は報告値が勝つ")
  }

  func testTitleChangeForwardsOnlyOnRealChange() {
    let tab = TerminalTab(cwd: "/tmp")
    var fired = 0
    tab.onTitleChange = { fired += 1 }
    tab.surface.title = "vim"
    tab.surface.title = "vim"
    XCTAssertEqual(fired, 1)
  }

  /// chrome の再投影はスロットの実変化で鳴る（状態語が同じでも文言・sessionId の更新は変化）。
  func testAgentSlotChangeFiresOnAgentStateChange() {
    let tab = TerminalTab(cwd: "/tmp")
    var fired = 0
    tab.onAgentStateChange = { fired += 1 }
    let at = Date(timeIntervalSince1970: 1000)
    setReportedState(tab, "working", at: at)
    setReportedState(tab, "working", at: at)  // 同値の再代入
    XCTAssertEqual(fired, 1)
    setReportedState(tab, "working", at: at, message: AgentMessage(text: "x", source: "tool"))
    XCTAssertEqual(fired, 2, "文言の更新はスロットの変化")
  }

  // MARK: - displayTitle の precedence（① explicitTitle ?? ② title ?? ③ derived）

  func testDisplayTitleExplicitWins() {
    let tab = TerminalTab(cwd: "/Users/me/proj/src")
    tab.surface.title = "vim"
    tab.explicitTitle = "build"
    XCTAssertEqual(
      tab.displayTitle(workspaceRoot: "/Users/me/proj"), "build", "① explicitTitle が最優先")
  }

  func testDisplayTitleFallsBackToSurfaceTitle() {
    let tab = TerminalTab(cwd: "/Users/me/proj/src")
    tab.surface.title = "vim"
    XCTAssertEqual(
      tab.displayTitle(workspaceRoot: "/Users/me/proj"), "vim", "明示なし → ② title(非空)")
  }

  func testDisplayTitleFallsBackToDerivedWhenTitleEmpty() {
    let tab = TerminalTab(cwd: "/Users/me/proj/src/app")
    XCTAssertEqual(
      tab.displayTitle(workspaceRoot: "/Users/me/proj"), "p/s/app",
      "明示なし・title 空 → ③ derived（圧縮アンカーは root の親＝先頭に root 名）")
  }

  func testDisplayTitleEmptyExplicitFallsThrough() {
    let tab = TerminalTab(cwd: "/tmp")
    tab.surface.title = "vim"
    tab.explicitTitle = ""  // 空は採用しない（②③へ戻る）
    XCTAssertEqual(tab.displayTitle(workspaceRoot: nil), "vim", "空の explicitTitle は無視し ② へ")
  }

  func testDisplayTitleIgnoresPwdFallbackTitle() {
    // libghostty は明示タイトル未受信の間、生 pwd を title に入れる（OSC 7 フォールバック）。
    // title == currentPwd ならそれは pwd フォールバックなので②を飛ばし③で圧縮整形する。
    let tab = TerminalTab(cwd: "/tmp")
    tab.surface.currentPwd = "/Users/me/proj/src/app"
    tab.surface.title = "/Users/me/proj/src/app"  // Ghostty の pwd フォールバックと同値
    XCTAssertEqual(
      tab.displayTitle(workspaceRoot: "/Users/me/proj"), "p/s/app",
      "title == currentPwd（pwd フォールバック）は ② にせず ③ で圧縮")
  }

  func testDisplayTitleKeepsAppTitleDifferingFromPwd() {
    // 本物のアプリタイトル（pwd と異なる）は②としてそのまま採用する。
    let tab = TerminalTab(cwd: "/tmp")
    tab.surface.currentPwd = "/Users/me/proj/src/app"
    tab.surface.title = "vim"
    XCTAssertEqual(
      tab.displayTitle(workspaceRoot: "/Users/me/proj"), "vim",
      "title != currentPwd は本物のアプリタイトル → ②")
  }

  // MARK: - tabState（復元単位）

  func testTabStateCarriesCwdSessionAndExplicitTitle() {
    let tab = TerminalTab(cwd: "/tmp")
    tab.surface.currentPwd = "/work"
    tab.explicitTitle = "api"
    let session = AgentSession(command: "claude", sessionId: "s-1")
    tab.agentSlot = .live(session: session, report: nil)
    XCTAssertEqual(
      tab.tabState(), TabState(cwd: "/work", agent: session, explicitTitle: "api"))
  }

  func testTabStateOmitsSessionWithoutId() {
    let tab = TerminalTab(cwd: "/tmp")
    setReportedState(tab, "working")  // sessionId 未確定
    XCTAssertNil(tab.tabState().agent, "resume 不能な同一性は書かない")
  }

  func testRestoringStateSeedsDormantSlotAndTitle() {
    let state = TabState(
      cwd: "/work", agent: AgentSession(command: "claude", sessionId: "s-1"), explicitTitle: "api")
    let tab = TerminalTab(restoring: state, resumeSpawn: { _ in nil })
    XCTAssertEqual(tab.surface.initialCwd, "/work")
    XCTAssertEqual(tab.explicitTitle, "api")
    XCTAssertTrue(tab.isDormant)
    XCTAssertFalse(tab.activated)
  }
}
