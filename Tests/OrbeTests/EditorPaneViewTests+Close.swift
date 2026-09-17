import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 閉じる——ファイルタブの × は焦点を動かさず、タブが消えれば面・ツリー・文書は解放され、同じ根を握る別のタブの
/// 監視は続く。
///
/// 壊れると何が起きるか。端末で打っている最中に隣の × を押すと打鍵がエディターへ移る。閉じたタブの面が根の
/// サービスを握り続けて、閉じたはずのリポジトリを監視し続ける（タブ数に比例して常時監視が増える）。
@MainActor
final class EditorPaneViewCloseTests: OrbeTestCase {
  func testFileTabCloseDoesNotMoveTheFocus() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }
    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    tab.view.layoutSubtreeIfNeeded()
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    tab.view.addSubview(outsider)
    XCTAssertTrue(window.makeFirstResponder(outsider))
    let a = try tab.editor.open(try caseFile("a.txt", "a"))
    let b = try tab.editor.open(try caseFile("b.txt", "b"))
    XCTAssertTrue(pane.document === b)

    pane.shell.requestClose(b.url)

    XCTAssertTrue(pane.document === a, "焦点の文書を閉じれば隣の文書が見える")
    let responder = try XCTUnwrap(window.firstResponder as? NSView)
    XCTAssertFalse(responder.isDescendant(of: pane), "面の外にあった焦点はそのまま")
    XCTAssertEqual(tab.faces.focus, .terminal, "面の記憶も動かない")
  }

  func testClosingATabFreesItsPaneWhileAnotherTabKeepsTheRootService() throws {
    let repo = try TempGitRepo()
    defer { repo.cleanup() }
    weak var pane: EditorPaneView?
    weak var tree: FileTree?
    weak var document: EditorDocument?
    weak var service: RootFiles?
    var keeper: TerminalTab? = TerminalTab(
      cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let keeperWindow = hostEditor(try XCTUnwrap(keeper), width: 900)

    try autoreleasepool {
      let tab = TerminalTab(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
      let window = hostEditor(tab, width: 900)
      let opened = try tab.editor.open(repo.url("a.txt"))
      window.makeFirstResponder(opened.surface.responder)
      pane = tab.view.editor
      tree = tab.view.editor.tree
      document = opened
      service = RootFiles.shared(for: repo.root)
      XCTAssertNotNil(service, "前提: 2 つのタブが同じ根を握っている")
      window.orderOut(nil)
      window.contentView = nil
    }

    pumpMain(until: { pane == nil && tree == nil && document == nil }, "タブが消えれば面・ツリー・文書は解放される")
    XCTAssertNotNil(service, "同じ根を握る別のタブが居る間、根のサービスは生きている")

    keeper = nil
    keeperWindow.contentView = nil
    pumpMain(until: { service == nil }, "最後の握り手が消えれば根のサービスも解放される")
  }
}
