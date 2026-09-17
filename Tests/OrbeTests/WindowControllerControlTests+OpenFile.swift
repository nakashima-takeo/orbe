import AppKit
import XCTest

@testable import Orbe

/// `open_file` の実体——ファイルが開いてエディター面が見え、そのタブが焦点になる。相対パスはタブの cwd から、
/// 未知のタブは -32004、開けないファイルは -32000 で面は変わらない。
///
/// 重要: 実 NSWindow に接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
extension WindowControllerControlTests {
  func testOpenFileShowsTheEditorAndFocusesTheTab() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let url = try caseFile("note.md", "# hi\n")
    let wc = try restore(
      activeWorkspace: 0,
      [
        tabbed(
          "main",
          tabs: [
            TabState(cwd: dir.path, agent: nil, explicitTitle: nil),
            TabState(cwd: dir.path, agent: nil, explicitTitle: nil),
          ])
      ])
    let tabs = wc.controlListTabs()
    let second = try XCTUnwrap(tabs[1]["tabId"] as? Int)
    let tab = try XCTUnwrap(wc.controlResolveTab(second))
    XCTAssertEqual(tab.faces, .terminalOnly)

    let result = wc.controlOpenFile(tabId: second, path: "note.md")
    guard case .success = result else { return XCTFail("\(result)") }
    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 1, focus: .editor), "隠れていれば全面")
    let opened = MainActor.assumeIsolated { tab.editor.activeDocument?.url }
    XCTAssertEqual(opened, url.resolvingSymlinksInPath())
    XCTAssertTrue(wc.controlListTabs()[1]["active"] as? Bool == true, "そのタブが選ばれる")
    XCTAssertTrue(wc.window.firstResponder === tab.focusTarget, "テキスト面へフォーカス")

    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    _ = wc.controlOpenFile(tabId: second, path: url.path)
    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 0.5, focus: .editor), "分割中は焦点だけ")
  }

  /// 一度も起きていない背景 workspace のタブ（前回開いていた文書を持つ）へ `open_file` すると、materialize の
  /// 復元に焦点を奪われず、要求したファイルが見える。
  func testOpenFileOnADormantTabKeepsTheRequestedDocumentActiveThroughRestore() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let a = try caseFile("a.txt", "a").resolvingSymlinksInPath()
    let c = try caseFile("c.txt", "c").resolvingSymlinksInPath()
    let wc = try restore(
      activeWorkspace: 0,
      [
        tabbed("main"),
        WorkspaceState(
          name: "bg", rootPath: dir.path, activeTab: 0,
          tabs: [
            TabState(
              cwd: dir.path, agent: nil, explicitTitle: nil,
              editor: EditorState(open: [a.path], active: a.path))
          ]),
      ])
    let tab = wc.workspaces[1].tabs[0]
    XCTAssertTrue(MainActor.assumeIsolated { tab.editor.documents.isEmpty }, "前提: まだ起きていない")

    let result = wc.controlOpenFile(tabId: tab.id, path: c.path)
    guard case .success = result else { return XCTFail("\(result)") }

    XCTAssertEqual(wc.activeWorkspace, 1, "そのタブの workspace が前面に出る")
    let (documents, active) = MainActor.assumeIsolated {
      (tab.editor.documents.map(\.url), tab.editor.activeDocument?.url)
    }
    XCTAssertEqual(active, c, "要求した文書が焦点のまま（復元が奪わない）")
    XCTAssertEqual(Set(documents), [a, c], "前回開いていた文書も戻る")
    let shown = MainActor.assumeIsolated { tab.view.editor.document?.url }
    XCTAssertEqual(shown, c, "面に載っているのも要求した文書")
  }

  func testOpenFileErrors() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let tabId = try XCTUnwrap(wc.controlListTabs()[0]["tabId"] as? Int)
    let tab = try XCTUnwrap(wc.controlResolveTab(tabId))

    if case .failure(let error) = wc.controlOpenFile(tabId: 999_999, path: "/tmp/x") {
      XCTAssertEqual(error.code, -32004)
    } else {
      XCTFail("未知のタブは -32004")
    }
    if case .failure(let error) = wc.controlOpenFile(tabId: tabId, path: "/nonexistent/x.txt") {
      XCTAssertEqual(error.code, -32000)
      XCTAssertEqual(error.message, "cannot read: /nonexistent/x.txt")
    } else {
      XCTFail("開けないファイルは -32000")
    }
    let binary = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("bin")
    try Data([0xff, 0xfe, 0xc3]).write(to: binary)
    if case .failure(let error) = wc.controlOpenFile(tabId: tabId, path: binary.path) {
      XCTAssertEqual(error.code, -32000)
      XCTAssertEqual(error.message, "not UTF-8: \(binary.path)")
    } else {
      XCTFail("UTF-8 でないファイルは -32000")
    }
    XCTAssertEqual(tab.faces, .terminalOnly, "失敗では面は変わらない")
    XCTAssertNil(MainActor.assumeIsolated { tab.editor.activeDocument })
  }
}
