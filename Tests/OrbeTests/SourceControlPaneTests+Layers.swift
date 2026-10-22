import AppKit
import XCTest

@testable import Orbe

/// 親「ソース管理」とグラフの枠（エディター面に結んだパネル）——親を畳むと、焦点のあった欄・列から本文へ焦点を移してから
/// 隠す。親を畳んだままソース管理を出しても、パネルの中へ焦点を求めない。グラフの列で押して働くのは「さらに表示」だけで、
/// 押しても変更の列の焦点と選択は動かない。境目を引くとグラフの枠の高さが変わり、離すと記憶へ書き戻す。
///
/// 壊れると何が起きるか。列で ↑↓ していて親を畳むと、焦点が窓へ落ちてキーがどこにも届かない（パネルは焦点があると思った
/// まま）。畳んだ親を開いた瞬間に、残っていた焦点の要求が本文の焦点を奪う。グラフのコミットを押すと、変更の列から焦点が
/// 抜けて ↑↓ が効かなくなる。「さらに表示」を押しても 50 件の先が出ない。境目を引いても枠が動かない・逆へ動く・
/// ポインタから離れて動く、離しても高さが残らず再起動で戻る。
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

  /// グラフの列のコミットを押しても何も起きず、「さらに表示」を押すと 50 件の先のコミットが出る。どちらでも変更の列の
  /// 焦点と選択はそのままで、続けて ↓ が効く。
  func testPressingTheGraphOnlyShowsMoreAndKeepsTheFocusOfTheChangesList() throws {
    let repo = try TempGitRepo()
    for n in 1...ScmPanel.graphPage {
      XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "c\(n)"]).isSuccess)
    }
    try repo.write("a.txt", "edited\n")
    try repo.write("b.txt", "new\n")
    let hosted = host(repo)
    let scm = hosted.scm
    let list = hosted.pane.scmList.list
    let graph = hosted.pane.scmGraphList.list
    func commits() -> Int {
      scm.graphLayout.items.filter { if case .commit = $0 { true } else { false } }.count
    }
    pumpMain(
      until: {
        list.rowCount == 3 && commits() == ScmPanel.graphPage
          && graph.rowCount == scm.graphLayout.items.count && graph.window != nil
      }, "変更の列と、続きのあるグラフの列")
    let selected = ScmRowID(section: .changes, path: "a.txt")
    scm.select(selected)
    hosted.window.makeFirstResponder(list)
    func press(row: Int) {
      let y = (CGFloat(row) + 0.5) * Theme.Layout.editorScmRow
      graph.scrollToVisible(NSRect(x: 0, y: y - 1, width: 1, height: 2))
      graph.mouseDown(
        with: .mouse(
          .leftMouseDown, at: graph.convert(NSPoint(x: 60, y: y), to: nil), in: hosted.window))
    }

    press(row: 1)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(commits(), ScmPanel.graphPage, "コミットは押しても何も起きない")
    press(row: scm.graphLayout.items.count - 1)
    pumpMain(until: { commits() == ScmPanel.graphPage + 1 }, "さらに表示で先のコミットが出る")
    XCTAssertFalse(scm.graphLayout.items.contains(.more), "続きが無くなれば、さらに表示は消える")
    XCTAssertTrue(hosted.window.firstResponder === list, "焦点は変更の列のまま")
    XCTAssertEqual(scm.selection, selected)
    list.keyDown(with: .key(String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!), []))
    XCTAssertEqual(scm.selection, ScmRowID(section: .changes, path: "b.txt"), "続けて ↓ が効く")
  }

  /// 境目を引くと、グラフの枠は掴んだときの高さから引いた分だけ伸び縮みし（上へ引けば伸びる）、離すと記憶へ書き戻す。
  func testDraggingTheBoundaryResizesTheGraphFrameAndWritesItBackOnRelease() throws {
    let hosted = host(try TempGitRepo(), showsPanel: false)
    hosted.window.setContentSize(NSSize(width: 900, height: 700))
    hosted.pane.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState.loaded(),
      diffModes: EditorDiffModeState())
    hosted.pane.shell.selectPanel(.sourceControl)
    let graph = hosted.pane.scmGraphList
    func graphFrameHeight() -> CGFloat {
      hosted.pane.layoutSubtreeIfNeeded()
      return graph.window == nil ? 0 : graph.frame.height + Theme.Layout.editorScmRow
    }
    let standard = Theme.Layout.editorScmGraph
    pumpMain(until: { graphFrameHeight() == standard }, "既定の高さのグラフの枠")
    let handle = try XCTUnwrap(splitHandle(in: hosted.pane))
    let grab = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
    func drag(rising rise: CGFloat) {
      handle.mouseDragged(
        with: .mouse(
          .leftMouseDragged, at: NSPoint(x: grab.x, y: grab.y + rise), in: hosted.window))
    }

    handle.mouseDown(with: .mouse(.leftMouseDown, at: grab, in: hosted.window))
    drag(rising: 40)
    pumpMain(until: { graphFrameHeight() == standard + 40 }, "上へ引けば伸びる")
    drag(rising: -50)
    pumpMain(until: { graphFrameHeight() == standard - 50 }, "掴んだときの高さから、引いた分だけ")
    XCTAssertEqual(
      AppStatePersistence.load()?.editorSidebar?.graphHeight, standard, "引いている間は書かない")
    handle.mouseUp(with: .mouse(.leftMouseUp, at: grab, in: hosted.window))
    XCTAssertEqual(
      AppStatePersistence.load()?.editorSidebar?.graphHeight, standard - 50, "離すと書き戻す")
  }

  /// 面に載っている境目の当たり（載っていなければ nil）。
  private func splitHandle(in view: NSView) -> ScmSplitHandleView? {
    (view as? ScmSplitHandleView) ?? view.subviews.lazy.compactMap(splitHandle(in:)).first
  }
}
