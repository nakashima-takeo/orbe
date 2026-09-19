import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// sheet は非同期に確定する——応答が返るまでにセッション・タブ・workspace が動いても、効くのは確認を出した
/// 対象だけで、消えていれば何もしない。書けない先への上書きは印を残す。
///
/// 壊れると何が起きるか。エージェントが `open_file` した別の文書が代わりに閉じられる／上書きされる。
/// 制御 API が別の workspace を畳んだ直後の応答で、指していない workspace が丸ごと消える。
extension UnsavedGateTests {
  private func hostPane(_ tab: TerminalTab) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = tab.view
    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    return window
  }

  /// ファイルタブの × の確認は、応答までに焦点が別の文書へ移っても、閉じるのは確認を出した文書。
  func testFileTabCloseSheetClosesTheDocumentItAskedAboutEvenIfTheFocusMoved() throws {
    let tab = TerminalTab(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostPane(tab)
    defer { window.orderOut(nil) }
    let a = try tab.editor.open(repo.url("a.txt"))
    edit(a)

    tab.view.editor.shell.requestClose(a.url)
    try repo.write("b.txt", "b\n")
    let b = try tab.editor.open(repo.url("b.txt"))  // sheet の間にエージェントが別の文書を開く
    window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)

    XCTAssertEqual(tab.editor.documents.map(\.url.lastPathComponent), ["b.txt"], "確認した文書だけ閉じる")
    XCTAssertTrue(tab.editor.activeDocument === b)
  }

  /// 上書き確認の応答までにその文書が閉じられていれば何もしない（ディスクを触らない）。
  func testOverwriteDoesNothingWhenTheDocumentWasClosedMeanwhile() throws {
    let tab = TerminalTab(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostPane(tab)
    defer { window.orderOut(nil) }
    let pane = tab.view.editor
    let a = try tab.editor.open(repo.url("a.txt"))
    window.makeFirstResponder(a.surface.responder)
    edit(a)
    try repo.write("a.txt", "outside\n")

    XCTAssertTrue(pane.performKeyEquivalent(with: .key("s")))
    let sheet = try XCTUnwrap(window.attachedSheet)
    tab.editor.close(a)
    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)

    XCTAssertEqual(try String(contentsOf: repo.url("a.txt"), encoding: .utf8), "outside\n")
  }

  /// 上書きも書けない先（親ディレクトリが書けない）では失敗し、印は立ったまま残る。
  func testOverwriteThatCannotWriteKeepsTheMarks() throws {
    let tab = TerminalTab(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostPane(tab)
    defer { window.orderOut(nil) }
    let pane = tab.view.editor
    let a = try tab.editor.open(repo.url("a.txt"))
    window.makeFirstResponder(a.surface.responder)
    edit(a)
    try repo.write("a.txt", "outside\n")
    pumpMain(until: { a.isDiskChanged }, "外部変更の印")

    XCTAssertTrue(pane.performKeyEquivalent(with: .key("s")))
    let sheet = try XCTUnwrap(window.attachedSheet)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: repo.root)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root)
    }
    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)

    XCTAssertEqual(try String(contentsOf: repo.url("a.txt"), encoding: .utf8), "outside\n", "触れない")
    XCTAssertTrue(a.isDirty)
    XCTAssertTrue(a.isDiskChanged, "印は立ったまま")
  }

  /// タブを閉じる確認の応答までにそのタブがシェル終了で消えていれば何もしない。
  func testGestureCloseSheetDoesNothingWhenTheTabIsAlreadyGone() throws {
    let wc = try restore([
      TabState(cwd: repo.root, agent: nil, explicitTitle: nil),
      TabState(cwd: repo.root, agent: nil, explicitTitle: nil),
    ])
    let first = try XCTUnwrap(wc.activeTab)
    let second = wc.current.tabs[1]
    edit(try first.editor.open(repo.url("a.txt")))

    wc.closeTab(first, origin: .gesture)
    let sheet = try XCTUnwrap(wc.window.attachedSheet)
    wc.closeTab(first, origin: .process)
    XCTAssertEqual(wc.current.tabs.count, 1, "シェル終了で先に消える")
    wc.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)

    XCTAssertEqual(wc.current.tabs.count, 1)
    XCTAssertTrue(wc.current.tabs[0] === second, "残っているタブには触れない")
  }

  /// workspace を閉じる確認の応答までに制御 API が別の workspace を畳んで位置がずれても、消えるのは確認を
  /// 出した workspace。
  func testCloseWorkspaceSheetTargetsTheWorkspaceItAskedAboutAfterAnotherIsRemoved() throws {
    let wc = try restore([TabState(cwd: repo.root, agent: nil, explicitTitle: nil)])
    wc.createWorkspace(name: "other", rootPath: repo.root)
    let other = wc.activeWorkspace
    edit(try XCTUnwrap(wc.activeTab).editor.open(repo.url("a.txt")))
    wc.createWorkspace(name: "third", rootPath: repo.root)
    XCTAssertEqual(wc.workspaces.map(\.name), ["main", "other", "third"])

    wc.closeWorkspace(other, origin: .gesture)
    let sheet = try XCTUnwrap(wc.window.attachedSheet)
    wc.closeWorkspace(0, origin: .controlAPI)
    XCTAssertEqual(wc.workspaces.map(\.name), ["other", "third"], "先頭が消えて位置がずれる")
    wc.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)

    XCTAssertEqual(wc.workspaces.map(\.name), ["third"], "確認した workspace だけが消える")
  }
}
