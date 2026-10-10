import OrbeTestSupport
import XCTest

@testable import Orbe

/// タブの所属キー（`groupKey`＝所属の連のキー）——cwd が属する git worktree ルート、管理外は cwd 自身（Q1）。
/// cwd が変わったときの付け替えは `WindowController` が行う（`WindowControllerTabGroupTests`）。
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

    let tab = TerminalTab.alone(restoring: state) { _, _, _ in nil }

    XCTAssertEqual(tab.groupKey, GitWorktreeRoot.normalizedPath(root.path))
  }

  /// cwd の報告（OSC 7）は上位へ知らせるだけで、所属は変えない（付け替えは `WindowController` が新しい根から決める）。
  func testPwdChangeNotifiesWithoutMovingTheGroup() throws {
    let root = try gitRoot()
    let tab = TerminalTab.alone(cwd: "/tmp")
    let group = tab.group
    let key = tab.groupKey
    var notified = false
    tab.onPwdChange = { notified = true }

    tab.surface.currentPwd = root.appendingPathComponent("src").path

    XCTAssertTrue(notified)
    XCTAssertTrue(tab.group === group)
    XCTAssertEqual(tab.groupKey, key)
  }
}
