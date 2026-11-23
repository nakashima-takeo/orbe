import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// `open_diff` の実体——Files の画面からでも Changes にして diff を本体に出し、左の列でその行を選び、そのタブのエディターが
/// 開き、焦点になる。パスは `open_file` と同じ解き方で根と相対パスになり、git 管理外は -32000、未知のタブは -32004。
///
/// 重要: 実 NSWindow に接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
extension WindowControllerControlTests {
  func testOpenDiffShowsTheDiffAndFocusesIt() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "changed\n")
    let wc = try restore(
      activeWorkspace: 0,
      [tabbed("main", tabs: [TabState(cwd: repo.root, agent: nil, explicitTitle: nil)])])
    let tabId = try XCTUnwrap(wc.controlListTabs(workspaceId: nil).get()[0]["tabId"] as? Int)
    let tab = try XCTUnwrap(wc.controlResolveTab(tabId))
    let pane = tab.group.view.editor
    MainActor.assumeIsolated { tab.group.editor.selectScreen(.files) }

    let result = wc.controlOpenDiff(tabId: tabId, path: "a.txt", kind: .workingTree)
    guard case .success = result else { return XCTFail("\(result)") }
    XCTAssertTrue(tab.group.view.isEditorOpen, "エディターが開く")
    let opened = try XCTUnwrap(MainActor.assumeIsolated { pane.diff }, "Files の画面からでも本体に出る")
    XCTAssertEqual(
      MainActor.assumeIsolated { opened.id },
      EditorDiff.Key(root: repo.root, path: "a.txt", kind: .workingTree), "根と根からの相対パスの diff")
    pumpMain(
      until: { MainActor.assumeIsolated { pane.diff?.content == .ready } }, "中身が届く")
    pumpMain(
      until: {
        MainActor.assumeIsolated {
          pane.scm.selection == ScmRowID(section: .changes, path: "a.txt")
        }
      }, "左の列でその行を選ぶ")
    _ = wc.controlOpenDiff(tabId: tabId, path: repo.url("a.txt").path, kind: .workingTree)
    XCTAssertTrue(
      wc.window.firstResponder === pane.focusTarget && pane.focusTarget !== pane,
      "開き直すと diff の面へフォーカス")
    XCTAssertTrue(
      MainActor.assumeIsolated { tab.group.editor.changesDiff } === opened, "同じ diff は開き直さない")
  }

  /// Changes の画面で左の列を開き、変更の列の行を待って焦点を預かっている間に `open_diff` が来ると、預かりは終わり、後から
  /// 行が出ても列は焦点を取らない（壊れると、エージェントが開いた diff ではなく後から出た列に焦点が着き、人の ↑↓ が列の移動に
  /// なる）。
  func testOpenDiffWhileTheChangesListHoldsTheFocusEndsTheHold() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "changed\n")
    try repo.write("b.txt", "new\n")
    let wc = try restore(
      activeWorkspace: 0,
      [tabbed("main", tabs: [TabState(cwd: repo.root, agent: nil, explicitTitle: nil)])])
    let tabId = try XCTUnwrap(wc.controlListTabs(workspaceId: nil).get()[0]["tabId"] as? Int)
    let tab = try XCTUnwrap(wc.controlResolveTab(tabId))
    let pane = tab.group.view.editor
    MainActor.assumeIsolated { tab.group.editor.selectScreen(.files) }
    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertTrue(MainActor.assumeIsolated { pane.sidebar.isOpen }, "前提: 左の列を開いている")
    pane.switchScreen(.changes)
    XCTAssertEqual(pane.heldListFocus, .changes, "前提: 行を待って焦点を預かる")

    let result = wc.controlOpenDiff(tabId: tabId, path: "b.txt", kind: .workingTree)
    guard case .success = result else { return XCTFail("\(result)") }
    XCTAssertNil(pane.heldListFocus, "open_diff で預かりが終わる")
    pumpMain(
      until: {
        MainActor.assumeIsolated { !pane.scm.layout.items.isEmpty && pane.diff?.content == .ready }
      }, "行と中身が出る")
    nextTurn()
    let responder = try XCTUnwrap(wc.window.firstResponder as? NSView)
    XCTAssertFalse(responder.isDescendant(of: pane.scmList.list), "後から出た列は焦点を取らない")
    XCTAssertNil(MainActor.assumeIsolated { pane.scm.focusRequest }, "列へ焦点を求めない")
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
    let tabId = try XCTUnwrap(wc.controlListTabs(workspaceId: nil).get()[0]["tabId"] as? Int)
    let tab = try XCTUnwrap(wc.controlResolveTab(tabId))

    let result = wc.controlOpenDiff(
      tabId: tabId, path: "/private" + repo.root + "/sub/b.txt", kind: .workingTree)
    guard case .success = result else { return XCTFail("\(result)") }
    XCTAssertEqual(
      MainActor.assumeIsolated { tab.group.editor.changesDiff?.id },
      EditorDiff.Key(root: repo.root, path: "sub/b.txt", kind: .workingTree))
  }

  func testOpenDiffErrors() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let tabId = try XCTUnwrap(wc.controlListTabs(workspaceId: nil).get()[0]["tabId"] as? Int)
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
