import OrbeTestSupport
import XCTest

@testable import Orbe

/// タブの所属キー（`groupKey`）——cwd が属する git worktree ルート、管理外は cwd 自身（Q1）。
/// cwd が変わったときに再計算され、`onPwdChange` が呼ばれる時点で新しいキーになっている
/// （`WindowController` はその中で `regroup` を呼ぶ）。
extension TerminalTabTests {

  private func gitRoot() throws -> URL {
    let root = TestScratch.caseDir.appendingPathComponent("orbe-tab-key")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    return root
  }

  /// 復元したタブは保存 cwd から同じ規則で導く（キーは永続しない）。
  func testRestoredTabDerivesGroupKeyFromSavedCwd() throws {
    let root = try gitRoot()
    let state = TabState(
      cwd: root.appendingPathComponent("src").path, agent: nil, explicitTitle: nil)

    let tab = TerminalTab(restoring: state) { _, _ in nil }

    XCTAssertEqual(tab.groupKey, GitWorktreeRoot.normalizedPath(root.path))
  }

  /// cwd の報告（OSC 7）でキーが再計算され、`onPwdChange` が呼ばれる時点で既に新しいキーになっている。
  func testPwdChangeRecomputesGroupKeyBeforeNotifying() throws {
    let root = try gitRoot()
    let tab = TerminalTab(cwd: "/tmp")
    var keyWhenNotified: String?
    tab.onPwdChange = { keyWhenNotified = tab.groupKey }

    tab.surface.currentPwd = root.appendingPathComponent("src").path

    XCTAssertEqual(keyWhenNotified, GitWorktreeRoot.normalizedPath(root.path), "通知時点で新キー")
    XCTAssertEqual(tab.groupKey, keyWhenNotified)
  }
}
