import AppKit
import XCTest

@testable import Orbe

/// 裏の fetch（実 git）: パネルを出していて Orbe が前面なら、手で何も押さなくても裏の fetch で先行・遅れが新しくなり、
/// worktree の操作の列（帯・失敗の文・ボタンの可否）には出ない。
///
/// 壊れると何が起きるか。別の clone で origin が進んでも「同期 ↓N」に気づけない・3 分ごとに帯や失敗の文が出入りする。
@MainActor
final class ScmAutoFetchPanelTests: OrbeTestCase {
  private var panel: ScmPanel?

  override func tearDown() {
    panel?.isShown = false
    panel?.isLive = false
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    super.tearDown()
  }

  func testAShownPanelInTheForegroundSeesTheRemoteAdvanceWithoutPressing() throws {
    let repo = try TempGitRepo()
    repo.addOrigin()
    try repo.advanceOrigin(writing: "o.txt", "o\n")
    let panel = ScmPanel(root: repo.root)
    self.panel = panel
    panel.isLive = true
    panel.isShown = true
    pumpMain(until: { panel.branch?.upstream?.divergence != nil }, "先行・遅れが出る")
    XCTAssertEqual(panel.branch?.upstream?.divergence?.behind, 0, "前提: まだ fetch していない")

    // テストのプロセスは前面にならないので、Orbe が前面に戻った知らせを送る。
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)

    pumpMain(
      until: { panel.branch?.upstream?.divergence?.behind == 1 }, timeout: 20, "裏の fetch で遅れが 1")
    XCTAssertTrue(panel.control.operations.isEmpty, "操作の列に載らない")
    XCTAssertNil(panel.control.failure)
  }
}
