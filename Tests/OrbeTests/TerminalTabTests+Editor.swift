import XCTest

@testable import Orbe

/// タブの復元単位とエディターの状態——開いている文書はそのまま書き、復元した状態は materialize で消費して開き、
/// 未消費のまま保存すれば同じ形で書き戻す。
///
/// 壊れると何が起きるか。一度も見なかったタブの文書が終了で失われる。復元で読めないファイルが復元を止める。
@MainActor
final class TerminalTabEditorTests: OrbeTestCase {
  private func file(_ name: String) throws -> URL {
    let url = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent(name)
    try Data("x".utf8).write(to: url)
    return url.resolvingSymlinksInPath()
  }

  func testTabStateCarriesOpenDocumentsAndTheActive() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    XCTAssertNil(tab.tabState().editor, "文書が無ければ書かない")
    let a = try tab.editor.open(try file("a.txt"))
    let b = try tab.editor.open(try file("b.txt"))
    tab.editor.activate(a)
    XCTAssertEqual(
      tab.tabState().editor, EditorState(open: [a.url.path, b.url.path], active: a.url.path))
  }

  func testRestoredStateIsKeptUntilMaterializationAndThenOpened() throws {
    let a = try file("a.txt")
    let state = TabState(
      cwd: "/tmp", agent: nil, explicitTitle: nil,
      editor: EditorState(open: [a.path, "/nonexistent/z.txt"], active: a.path))
    let tab = TerminalTab(restoring: state, resumeSpawn: { _ in nil })
    XCTAssertTrue(tab.editor.documents.isEmpty, "復元時は開かない")
    XCTAssertEqual(tab.tabState().editor, state.editor, "未消費のまま同じ形で書き戻す")

    var changes = 0
    tab.onEditorChange = { changes += 1 }
    tab.recordMaterializationStarted()
    XCTAssertEqual(tab.editor.documents.map(\.url), [a], "読めないパスは黙って落ちる")
    XCTAssertEqual(tab.editor.activeDocument?.url, a)
    XCTAssertEqual(changes, 1)
    XCTAssertEqual(
      tab.tabState().editor, EditorState(open: [a.path], active: a.path), "以後は開いている文書を書く")

    tab.editor.close(try XCTUnwrap(tab.editor.activeDocument))
    XCTAssertNil(tab.tabState().editor, "全部閉じれば消費済みの状態は戻らない")
  }
}
