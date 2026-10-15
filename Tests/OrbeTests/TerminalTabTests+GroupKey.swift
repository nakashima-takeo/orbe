import OrbeTestSupport
import XCTest

@testable import Orbe

/// タブの cwd の報告は所属を変えない。連のキーの導出と付け替えは `WindowController` が行う
/// （`WindowControllerTabGroupTests`）。
extension TerminalTabTests {

  private func gitRoot() throws -> URL {
    let root = TestScratch.caseDir.appendingPathComponent("orbe-tab-key")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    return root
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
