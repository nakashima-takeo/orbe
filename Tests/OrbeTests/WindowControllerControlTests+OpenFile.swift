import AppKit
import XCTest

@testable import Orbe

/// `open_file` の実体——ファイルが開いてエディター面が見え、そのタブが焦点になる。相対パスはタブの cwd から、
/// 未知のタブは -32004、開けないファイルは -32000 で面は変わらない。
///
/// 重要: 実 NSWindow に接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
extension WindowControllerControlTests {
  private func caseFile(_ name: String, _ text: String) throws -> URL {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

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
    let opened = MainActor.assumeIsolated { tab.editor.activeDocument?.url.standardizedFileURL }
    XCTAssertEqual(opened, url.standardizedFileURL)
    XCTAssertTrue(wc.controlListTabs()[1]["active"] as? Bool == true, "そのタブが選ばれる")
    XCTAssertTrue(wc.window.firstResponder === tab.focusTarget, "テキスト面へフォーカス")

    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    _ = wc.controlOpenFile(tabId: second, path: url.path)
    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 0.5, focus: .editor), "分割中は焦点だけ")
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
    } else {
      XCTFail("開けないファイルは -32000")
    }
    XCTAssertEqual(tab.faces, .terminalOnly, "失敗では面は変わらない")
    XCTAssertNil(MainActor.assumeIsolated { tab.editor.activeDocument })
  }
}
