import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe

/// タブの復元単位とエディターの状態——開いている文書と仮のタブはそのまま書き、復元した状態は materialize で消費して開き
/// （仮のタブは仮のまま）、未消費のまま保存すれば同じ形で書き戻す。検索の問いは復元で入力欄に戻り（探さない）、変えれば
/// 書き戻す。制御 API の `open_file` は普通のタブで開く。
///
/// 壊れると何が起きるか。一度も見なかったタブの文書が終了で失われる。復元で読めないファイルが復元を止める。再起動で
/// 仮のタブが普通のタブとして積もる。エージェントが見せたファイルを人の次のクリックが黙って入れ替える。再起動で
/// タブの検索語と切替が消える、復元のたびに根の全体を探す。
@MainActor
final class TerminalTabEditorTests: OrbeTestCase {
  private func file(_ name: String) throws -> URL {
    let url = TestScratch.caseDir.appendingPathComponent(name)
    try Data("x".utf8).write(to: url)
    return url.resolvingSymlinksInPath()
  }

  func testTabStateCarriesOpenDocumentsAndTheActive() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    XCTAssertNil(tab.tabState().editor, "文書が無ければ書かない")
    let a = try tab.editor.open(try file("a.txt"), as: .pinned)
    let b = try tab.editor.open(try file("b.txt"), as: .preview)
    tab.editor.activate(a)
    XCTAssertEqual(
      tab.tabState().editor,
      EditorState(
        documents: .init(open: [a.url.path, b.url.path], active: a.url.path, preview: b.url.path)))
  }

  /// `open_file` は普通のタブで開き、仮のタブで開いているファイルなら普通のタブに変える。
  func testOpenFileOpensAPinnedTab() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    try tab.openFile(try file("a.txt"))
    XCTAssertNil(tab.editor.preview)
    let b = try tab.editor.open(try file("b.txt"), as: .preview)
    try tab.openFile(b.url)
    XCTAssertNil(tab.editor.preview, "仮のタブは普通に変わる")
  }

  func testRestoredStateIsKeptUntilMaterializationAndThenOpened() throws {
    let a = try file("a.txt")
    let state = TabState(
      cwd: "/tmp", agent: nil, explicitTitle: nil,
      editor: EditorState(
        documents: .init(open: [a.path, "/nonexistent/z.txt"], active: a.path, preview: a.path)))
    let tab = TerminalTab(restoring: state, resumeSpawn: { _, _, _ in nil })
    XCTAssertTrue(tab.editor.documents.isEmpty, "復元時は開かない")
    XCTAssertEqual(tab.tabState().editor, state.editor, "未消費のまま同じ形で書き戻す")

    var changes = 0
    tab.onEditorChange = { changes += 1 }
    tab.recordMaterializationStarted()
    XCTAssertEqual(tab.editor.documents.map(\.url), [a], "読めないパスは黙って落ちる")
    XCTAssertEqual(tab.editor.activeDocument?.url, a)
    XCTAssertEqual(tab.editor.preview?.url, a, "仮のタブは仮のまま戻る")
    XCTAssertEqual(changes, 1)
    XCTAssertEqual(
      tab.tabState().editor,
      EditorState(documents: .init(open: [a.path], active: a.path, preview: a.path)),
      "以後は開いている文書を書く")

    tab.editor.close(try XCTUnwrap(tab.editor.activeDocument))
    XCTAssertNil(tab.tabState().editor, "全部閉じれば消費済みの状態は戻らない")
  }

  func testTheSearchQueryIsRestoredWithoutSearchingAndWrittenBack() throws {
    let query = SearchQuery(pattern: "needle", wholeWord: true)
    let tab = TerminalTab(
      restoring: TabState(
        cwd: "/tmp", agent: nil, explicitTitle: nil, editor: EditorState(search: query)),
      resumeSpawn: { _, _, _ in nil })
    let search = tab.view.editor.projectSearch
    XCTAssertEqual(search.query, query, "入力欄に戻る")
    XCTAssertEqual(search.phase, .idle, "復元では探さない")
    XCTAssertEqual(tab.tabState().editor, EditorState(search: query))

    var changes = 0
    tab.onEditorChange = { changes += 1 }
    search.toggle(.matchCase)
    XCTAssertEqual(changes, 1, "問いの変化は保存のきっかけ")
    XCTAssertEqual(
      tab.tabState().editor?.search,
      SearchQuery(pattern: "needle", matchCase: true, wholeWord: true))
  }
}
