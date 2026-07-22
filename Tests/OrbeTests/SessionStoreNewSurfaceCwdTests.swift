import XCTest

@testable import Orbe

/// SessionStore.newSurfaceCwd() の純ドメイン契約を固定する。
///
/// newSurfaceCwd は新規タブ/エージェント起動の初期 cwd を必ず確定させる：アクティブペインの cwd
/// （currentPwd ?? initialCwd）を継ぎ、ペイン不在（0タブ）は workspace の rootPath へ落とす。
/// nil を surface へ渡すと ghostty がホームへ解決してしまうため、非 Optional であること自体が契約。
final class SessionStoreNewSurfaceCwdTests: XCTestCase {

  private func makeStore(rootPath: String, tabs: [TerminalController]) -> SessionStore {
    let ws = Workspace(name: "ws", rootPath: rootPath)
    ws.tabs = tabs
    ws.active = 0
    return (SessionStore(workspaces: [ws], activeWorkspace: 0))
  }

  /// 0タブ：アクティブペインが無いので workspace の rootPath へ落ちる（ホームには落ちない）。
  func testZeroTabsFallsBackToWorkspaceRootPath() {
    let store = makeStore(rootPath: "/tmp/ws-root", tabs: [])
    XCTAssertEqual(store.newSurfaceCwd(), "/tmp/ws-root")
  }

  /// タブ有り：アクティブペインの cwd（ここでは initialCwd）を継ぎ、rootPath は使わない。
  func testActivePaneCwdWinsOverRootPath() {
    let store = makeStore(
      rootPath: "/tmp/ws-root", tabs: [TerminalController(initialCwd: "/tmp/pane-cwd")])
    XCTAssertEqual(store.newSurfaceCwd(), "/tmp/pane-cwd")
  }

  /// タブは有るがペインが cwd を持たない（currentPwd も initialCwd も nil）場合も rootPath へ落ちる。
  func testPaneWithoutCwdFallsBackToRootPath() {
    let store = makeStore(rootPath: "/tmp/ws-root", tabs: [TerminalController()])
    XCTAssertEqual(store.newSurfaceCwd(), "/tmp/ws-root")
  }
}
