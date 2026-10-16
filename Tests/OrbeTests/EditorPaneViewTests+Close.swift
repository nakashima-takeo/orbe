import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 閉じる——ファイルタブの × は焦点を動かさず、連が消えれば（最後のタブが閉じれば）面・ツリー・文書は解放され、
/// 同じ根を握る別の連（別の workspace の同じ worktree）の監視は続く。
///
/// 壊れると何が起きるか。端末で打っている最中に隣の × を押すと打鍵がエディターへ移る。消えた連の面が根の
/// サービスを握り続けて、閉じたはずのリポジトリを監視し続ける（連の数に比例して常時監視が増える）。
@MainActor
final class EditorPaneViewCloseTests: OrbeTestCase {
  func testFileTabCloseDoesNotMoveTheFocus() throws {
    let dir = TestScratch.caseDir
    let tab = TerminalTab.alone(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }
    tab.group.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    tab.group.view.layoutSubtreeIfNeeded()
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    tab.group.view.addSubview(outsider)
    XCTAssertTrue(window.makeFirstResponder(outsider))
    let a = try tab.group.editor.open(try caseFile("a.txt", "a"), as: .pinned)
    let b = try tab.group.editor.open(try caseFile("b.txt", "b"), as: .pinned)
    XCTAssertTrue(pane.document === b)

    pane.shell.requestClose(.document(b.url))

    XCTAssertTrue(pane.document === a, "焦点の文書を閉じれば隣の文書が見える")
    let responder = try XCTUnwrap(window.firstResponder as? NSView)
    XCTAssertFalse(responder.isDescendant(of: pane), "面の外にあった焦点はそのまま")
    XCTAssertEqual(tab.group.faces.focus, .terminal, "面の記憶も動かない")
  }

  func testReleasingAGroupFreesItsPaneWhileAnotherGroupKeepsTheRootService() throws {
    let repo = try TempGitRepo()
    weak var pane: EditorPaneView?
    weak var tree: FileTree?
    weak var document: EditorDocument?
    weak var service: RootFiles?
    var keeper: TerminalTab? = TerminalTab.alone(
      cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let keeperWindow = hostEditor(try XCTUnwrap(keeper), width: 900)

    try autoreleasepool {
      let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
      let window = hostEditor(tab, width: 900)
      let opened = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
      window.makeFirstResponder(opened.surface.responder)
      pane = tab.group.view.editor
      tree = tab.group.view.editor.tree
      document = opened
      service = RootFiles.shared(for: repo.root)
      XCTAssertNotNil(service, "前提: 2 つの連が同じ根を握っている")
      window.orderOut(nil)
      window.contentView = nil
    }

    pumpMain(until: { pane == nil && tree == nil && document == nil }, "連が消えれば面・ツリー・文書は解放される")
    XCTAssertNotNil(service, "同じ根を握る別の連が居る間、根のサービスは生きている")

    keeper = nil
    keeperWindow.contentView = nil
    pumpMain(until: { service == nil }, "最後の握り手が消えれば根のサービスも解放される")
  }
}
