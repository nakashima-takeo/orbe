import XCTest

@testable import Orbe

/// SessionStore の cwd 読み口——`newTabCwd(inWorkspaceAt:)` と `activeTabCwd()`——の純ドメイン契約を固定する。
///
/// newTabCwd(inWorkspaceAt:) は新規タブ/エージェント起動の初期 cwd を必ず確定させる：アクティブタブの cwd
/// （currentPwd ?? initialCwd）を継ぎ、タブ不在（0タブ）は workspace の rootPath へ落とす。
/// nil を surface へ渡すと ghostty がホームへ解決してしまうため、非 Optional であること自体が契約。
///
/// activeTabCwd() は「今見ているタブの cwd」（chrome の cwd 表示・エディタで開く・Dispatch の基点・
/// 新 workspace の既定 root が読む）で、アクティブ workspace の選択タブだけを見る。0 タブなら nil。
final class SessionStoreCwdTests: OrbeTestCase {

  private func makeStore(rootPath: String, tabs: [TerminalTab]) -> SessionStore {
    let ws = Workspace(name: "ws", rootPath: rootPath)
    ws.tabs = tabs
    ws.active = 0
    return (SessionStore(workspaces: [ws], activeWorkspace: 0))
  }

  /// 0タブ：アクティブタブが無いので workspace の rootPath へ落ちる（ホームには落ちない）。
  func testZeroTabsFallsBackToWorkspaceRootPath() {
    let store = makeStore(rootPath: "/tmp/ws-root", tabs: [])
    XCTAssertEqual(store.newTabCwd(inWorkspaceAt: 0), "/tmp/ws-root")
  }

  /// タブ有り：アクティブタブの cwd（ここでは initialCwd）を継ぎ、rootPath は使わない。
  func testActiveTabCwdWinsOverRootPath() {
    let store = makeStore(rootPath: "/tmp/ws-root", tabs: [TerminalTab(cwd: "/tmp/tab-cwd")])
    XCTAssertEqual(store.newTabCwd(inWorkspaceAt: 0), "/tmp/tab-cwd")
  }

  /// OSC 7 の報告があればそちらが勝つ（`TerminalTab.cwd` の定義）。
  func testReportedPwdWinsOverInitialCwd() {
    let tab = TerminalTab(cwd: "/tmp/tab-cwd")
    tab.surface.currentPwd = "/tmp/reported"
    let store = makeStore(rootPath: "/tmp/ws-root", tabs: [tab])
    XCTAssertEqual(store.newTabCwd(inWorkspaceAt: 0), "/tmp/reported")
  }

  // MARK: - activeTabCwd

  /// 0 タブは nil——rootPath へは落ちない（読み手が「タブが無い」を自分の既定で扱う）。
  func testActiveTabCwdIsNilWithoutTabs() {
    let store = makeStore(rootPath: "/tmp/ws-root", tabs: [])
    XCTAssertNil(store.activeTabCwd())
  }

  /// アクティブ workspace の選択タブの cwd（報告があれば報告値）——別タブ・別 workspace は見ない。
  func testActiveTabCwdFollowsTheSelectedTabOfTheActiveWorkspace() {
    let background = Workspace(name: "background", rootPath: "/tmp/bg")
    background.tabs = [TerminalTab(cwd: "/tmp/bg/tab")]
    background.active = 0
    let active = Workspace(name: "active", rootPath: "/tmp/ws-root")
    let viewed = TerminalTab(cwd: "/tmp/viewed")
    viewed.surface.currentPwd = "/tmp/viewed/reported"
    active.tabs = [TerminalTab(cwd: "/tmp/other"), viewed]
    active.active = 1
    let store = SessionStore(workspaces: [background, active], activeWorkspace: 1)

    XCTAssertEqual(store.activeTabCwd(), "/tmp/viewed/reported")
  }
}
