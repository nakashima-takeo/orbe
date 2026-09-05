import AppKit
import XCTest

@testable import Orbe

/// Dispatch パレットに渡すタブ占有（`TabOccupancy`）が全 workspace × 全タブ（休眠 workspace も含む）
/// から組まれることを固定する。占有は「そのパスをタブが開いている worktree は消せない」の判定材料で、
/// 前面 workspace だけを見ると背景で開いたままの worktree を掃除できてしまう。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerDispatchOccupancyTests: OrbeTestCase {

  /// 前面 workspace（素のタブ 1 枚）と、休眠 workspace（agent 付きタブ 1 枚）で起動する。
  private func restore() throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp/wt/a", agent: nil, explicitTitle: nil)]),
        WorkspaceState(
          name: "dormant", rootPath: "/tmp", activeTab: 0,
          tabs: [
            TabState(
              cwd: "/tmp/wt/c", agent: AgentSession(command: "claude", sessionId: "s-1"),
              explicitTitle: nil)
          ]),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  /// 前面タブは報告済み cwd と agent 状態を、休眠 workspace のタブは復元 cwd（agent 状態なし）を載せる。
  func testDispatchReceivesOccupancyOfEveryTabIncludingDormantWorkspaces() throws {
    let wc = try restore()
    let viewed = try XCTUnwrap(wc.current.tabs.first)
    viewed.surface.currentPwd = "/tmp/wt/a/reported"
    setReportedState(viewed, "working")
    XCTAssertFalse(try XCTUnwrap(wc.workspaces.last).activated, "前提: 背景 workspace は休眠")

    wc.showDispatchPalette()
    defer { wc.dismissPalette() }

    let occupancies = try XCTUnwrap(wc.model.dispatchProvider?.tabOccupancies)
    XCTAssertEqual(
      occupancies,
      [
        TabOccupancy(cwd: "/tmp/wt/a/reported", agentState: "working"),
        TabOccupancy(cwd: "/tmp/wt/c", agentState: nil),
      ], "全 workspace の全タブを実効 cwd と agent 状態で載せる（休眠 workspace も落とさない）")
  }
}
