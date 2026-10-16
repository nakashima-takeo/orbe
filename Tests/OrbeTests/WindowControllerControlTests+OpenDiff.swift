import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// `open_diff` の実体——diff のタブが開いてエディター面が見え、そのタブが焦点になる。パスは `open_file` と同じ解き方で
/// 根と相対パスになり、git 管理外は -32000、未知のタブは -32004。
///
/// 重要: 実 NSWindow に接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
extension WindowControllerControlTests {
  func testOpenDiffShowsTheDiffTabAndFocusesIt() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "changed\n")
    let wc = try restore(
      activeWorkspace: 0,
      [tabbed("main", tabs: [TabState(cwd: repo.root, agent: nil, explicitTitle: nil)])])
    let tabId = try XCTUnwrap(wc.controlListTabs()[0]["tabId"] as? Int)
    let tab = try XCTUnwrap(wc.controlResolveTab(tabId))

    let result = wc.controlOpenDiff(tabId: tabId, path: "a.txt", kind: .workingTree)
    guard case .success = result else { return XCTFail("\(result)") }
    XCTAssertEqual(tab.group.faces, FaceLayout(editorRatio: 1, focus: .editor), "隠れていれば全面")
    let active = MainActor.assumeIsolated { tab.group.editor.activeID }
    XCTAssertEqual(
      active, .diff(EditorDiff.Key(root: repo.root, path: "a.txt", kind: .workingTree)),
      "根と根からの相対パスの diff")
    pumpMain(
      until: { MainActor.assumeIsolated { tab.group.view.editor.diff?.content == .ready } },
      "中身が届く")
    _ = wc.controlOpenDiff(tabId: tabId, path: repo.url("a.txt").path, kind: .workingTree)
    XCTAssertTrue(
      wc.window.firstResponder === tab.focusTarget && tab.focusTarget !== tab.group.view.editor,
      "開き直すと diff の面へフォーカス")
    XCTAssertEqual(MainActor.assumeIsolated { tab.group.editor.tabs.count }, 1, "同じ diff はタブを増やさない")
  }

  /// 根の下の階層にあるファイルは、親ごと消えていても、`/private` を含む綴りでも、根と根からの相対パスの diff になる。
  func testOpenDiffTakesAFileGoneWithItsParentDirectory() throws {
    let repo = try TempGitRepo()
    XCTAssertTrue(repo.root.hasPrefix("/var/"), "前提: 根は /private を畳んだ綴り")
    try repo.write("sub/b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "sub"]).isSuccess)
    try FileManager.default.removeItem(at: repo.dir.appendingPathComponent("sub"))
    let wc = try restore(
      activeWorkspace: 0,
      [tabbed("main", tabs: [TabState(cwd: repo.root, agent: nil, explicitTitle: nil)])])
    let tabId = try XCTUnwrap(wc.controlListTabs()[0]["tabId"] as? Int)
    let tab = try XCTUnwrap(wc.controlResolveTab(tabId))

    let result = wc.controlOpenDiff(
      tabId: tabId, path: "/private" + repo.root + "/sub/b.txt", kind: .workingTree)
    guard case .success = result else { return XCTFail("\(result)") }
    XCTAssertEqual(
      MainActor.assumeIsolated { tab.group.editor.activeID },
      .diff(EditorDiff.Key(root: repo.root, path: "sub/b.txt", kind: .workingTree)))
  }

  func testOpenDiffErrors() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let tabId = try XCTUnwrap(wc.controlListTabs()[0]["tabId"] as? Int)
    if case .failure(let error) = wc.controlOpenDiff(tabId: 999_999, path: "/tmp/x", kind: .staged)
    {
      XCTAssertEqual(error.code, -32004)
    } else {
      XCTFail("未知のタブ")
    }
    let outside = try caseFile("plain.txt", "x")
    if case .failure(let error) = wc.controlOpenDiff(
      tabId: tabId, path: outside.path, kind: .workingTree)
    {
      XCTAssertEqual(error.code, -32000, "git 管理外")
    } else {
      XCTFail("git 管理外は断る")
    }
  }
}
