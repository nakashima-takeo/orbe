import AppKit
import XCTest

@testable import Orbe

/// 親「ソース管理」とグラフの枠（エディター面に結んだパネル）——親を畳むと、焦点のあった欄・列から本文へ焦点を移してから
/// 隠す。親を畳んだままソース管理を出しても、パネルの中へ焦点を求めない。グラフの列を押しても、変更の列の焦点と選択は動かない。
///
/// 壊れると何が起きるか。列で ↑↓ していて親を畳むと、焦点が窓へ落ちてキーがどこにも届かない（パネルは焦点があると思った
/// まま）。畳んだ親を開いた瞬間に、残っていた焦点の要求が本文の焦点を奪う。グラフのコミットを押すと、変更の列から焦点が
/// 抜けて ↑↓ が効かなくなる。
extension SourceControlPaneTests {
  /// 変更 a.txt・b.txt と 1 コミットのグラフが出た面。
  private func layersPane() throws -> Hosted {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    try repo.write("b.txt", "new\n")
    let hosted = host(repo)
    let scm = hosted.scm
    pumpMain(
      until: {
        scm.changes.changes.count == 2 && hosted.pane.scmList.list.rowCount == 3
          && scm.graphLayout.items.contains { if case .commit = $0 { true } else { false } }
          && hosted.pane.scmGraphList.list.rowCount == scm.graphLayout.items.count
      }, "変更の列とグラフの列")
    return hosted
  }

  /// 変更の列に焦点がある状態で親を畳むと、列が窓から外れる前に焦点が本文へ移る。選択は残り、開いた後に列を押せば列が
  /// 焦点を取り直す。
  func testClosingTheRepositoryMovesTheFocusFromTheListToTheBody() throws {
    let hosted = try layersPane()
    let scm = hosted.scm
    let list = hosted.pane.scmList.list
    let selected = ScmRowID(section: .changes, path: "a.txt")
    scm.select(selected)
    hosted.window.makeFirstResponder(list)
    XCTAssertEqual(scm.focusedArea, .list, "前提: 列に焦点")

    scm.setRepositoryOpen(false)
    pumpMain(until: { list.window == nil }, "列が窓から外れる")
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane, "焦点は本文の行き先へ")
    XCTAssertNil(scm.focusedArea)
    XCTAssertEqual(scm.selection, selected, "選択は残る")

    scm.setRepositoryOpen(true)
    pumpMain(until: { list.window != nil }, "列が戻る")
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane, "開いても焦点は奪わない")
    list.mouseDown(
      with: .mouse(
        .leftMouseDown, at: list.convert(NSPoint(x: 60, y: 33), to: nil), in: hosted.window))
    XCTAssertTrue(hosted.window.firstResponder === list, "押せば列が焦点を取り直す")
  }

  /// 親を畳んだままレールでソース管理を出し直しても、パネルの中へ焦点を求めない。開いても焦点は本文のまま。
  func testShowingThePanelWhileTheRepositoryIsClosedRequestsNoFocus() throws {
    let hosted = try layersPane()
    let scm = hosted.scm
    scm.setRepositoryOpen(false)
    hosted.pane.shell.selectPanel(.files)
    hosted.pane.shell.selectPanel(.sourceControl)
    XCTAssertNil(scm.focusRequest)
    scm.setRepositoryOpen(true)
    pumpMain(until: { hosted.pane.scmList.list.window != nil }, "列が戻る")
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertNil(scm.focusedArea, "開いても焦点を奪わない")
  }

  /// グラフの列のコミットを押しても、変更の列の焦点と選択はそのままで、続けて ↑↓ が効く。
  func testPressingTheGraphKeepsTheFocusAndSelectionOfTheChangesList() throws {
    let hosted = try layersPane()
    let scm = hosted.scm
    let list = hosted.pane.scmList.list
    let graph = hosted.pane.scmGraphList.list
    scm.select(ScmRowID(section: .changes, path: "a.txt"))
    hosted.window.makeFirstResponder(list)
    pumpMain(until: { graph.window != nil && graph.visibleRect.height > 0 }, "グラフの列が見える")

    let commit = graph.convert(NSPoint(x: 60, y: 1.5 * Theme.Layout.editorScmRow), to: nil)
    graph.mouseDown(with: .mouse(.leftMouseDown, at: commit, in: hosted.window))
    XCTAssertTrue(hosted.window.firstResponder === list, "焦点は変更の列のまま")
    XCTAssertEqual(scm.selection, ScmRowID(section: .changes, path: "a.txt"))
    list.keyDown(with: .key(String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!), []))
    XCTAssertEqual(scm.selection, ScmRowID(section: .changes, path: "b.txt"), "続けて ↓ が効く")
  }
}
