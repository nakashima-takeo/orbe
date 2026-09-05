import XCTest

@testable import Orbe

/// SessionStore.newTabCwd(inWorkspaceAt:) の純ドメイン契約を固定する。
///
/// newTabCwd(inWorkspaceAt:) は新規タブ/エージェント起動の初期 cwd を必ず確定させる：アクティブタブの cwd
/// （currentPwd ?? initialCwd）を継ぎ、タブ不在（0タブ）は workspace の rootPath へ落とす。
/// nil を surface へ渡すと ghostty がホームへ解決してしまうため、非 Optional であること自体が契約。
final class SessionStoreNewSurfaceCwdTests: OrbeTestCase {

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
}
