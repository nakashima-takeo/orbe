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

  /// symlink は実体へ解いて開く——保存（一時ファイルの rename）がリンクを通常ファイルに置き換えず、
  /// 実体へ届く。リンク経由と実体のパスで開いても同じ 1 文書。
  func testOpenFileResolvesSymlinksSoSavingReachesTheTarget() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let target = try caseFile("real.txt", "OLD")
    let link = dir.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let wc = try restore(
      activeWorkspace: 0,
      [tabbed("main", tabs: [TabState(cwd: dir.path, agent: nil, explicitTitle: nil)])])
    let tabId = try XCTUnwrap(wc.controlListTabs()[0]["tabId"] as? Int)
    let tab = try XCTUnwrap(wc.controlResolveTab(tabId))

    guard case .success = wc.controlOpenFile(tabId: tabId, path: "link.txt") else {
      return XCTFail("リンク経由で開ける")
    }
    guard case .success = wc.controlOpenFile(tabId: tabId, path: target.path) else {
      return XCTFail("実体のパスでも開ける")
    }
    let (count, opened) = MainActor.assumeIsolated {
      (tab.editor.documents.count, tab.editor.documents.first?.url)
    }
    XCTAssertEqual(count, 1, "同じ実体は 1 文書")
    XCTAssertEqual(opened, target.resolvingSymlinksInPath())

    try MainActor.assumeIsolated {
      let responder = try XCTUnwrap(tab.editor.activeDocument?.surface.responder)
      responder.perform(Selector(("insertText:")), with: "NEW ")
      try tab.editor.saveActive()
    }
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "NEW OLD", "実体へ書かれる")
    let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
    XCTAssertEqual(
      attributes[.type] as? FileAttributeType, .typeSymbolicLink, "リンクは通常ファイルにならない")
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
