import AppKit
import Metal
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 新しいテキスト面（Metal）を選んだタブで、エディター面の今の働き——開く・切り替える・閉じる・再起動の復元・
/// スクロールバーからのスクロール・⌘F の次でのスクロール——が同じように動く。壊れると設定を真にした人の文書が
/// 開かない・俯瞰で動かない・一致が見えない・復元で今の面に戻る。
@MainActor
final class EditorMetalEngineTests: OrbeTestCase {
  private let metal = EditorEngineChoice(
    metal: true, elasticScroll: true, fontSmoothing: true, language: .ja)

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal の装置が無い環境では今の面で開く")
  }

  private var surfaces: EditorSurfaces {
    let choice = metal
    return EditorSurfaces(queriesRoot: nil, engine: { choice })
  }

  private func isMetal(_ document: EditorDocument) -> Bool {
    String(describing: type(of: document.surface)) == "MetalTextSurface"
  }

  private func lines(_ count: Int) -> String {
    (0..<count).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
  }

  func testOpensSwitchesAndClosesWithTheNewSurface() throws {
    let tab = TerminalTab(cwd: try XCTUnwrap(TestIsolation.caseDir).path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let a = try tab.editor.open(try caseFile("a.swift", lines(400)))
    let b = try tab.editor.open(try caseFile("b.swift", lines(10)))
    XCTAssertTrue(isMetal(a) && isMetal(b))
    tab.editor.activate(a)
    tab.view.editor.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(a.surface.viewport.visibleLines, 0, "焦点の文書の面が本体に載って大きさを持つ")
    tab.editor.close(b)
    XCTAssertEqual(tab.editor.documents.count, 1)
  }

  /// スクロールバーのトラックを押すとその場で本文が動き、⌘F の次は一致の行を中央に見せる。
  func testOverviewAndFindScrollTheNewSurface() throws {
    let tab = TerminalTab(cwd: try XCTUnwrap(TestIsolation.caseDir).path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let document = try tab.editor.open(try caseFile("a.swift", lines(2000)))
    XCTAssertTrue(isMetal(document))
    let pane = tab.view.editor
    pane.layoutSubtreeIfNeeded()
    let bar = pane.scrollbar
    bar.mouseDown(
      with: bar.mouseEvent(.leftMouseDown, at: NSPoint(x: bar.bounds.midX, y: bar.bounds.maxY - 20))
    )
    bar.mouseUp(
      with: bar.mouseEvent(.leftMouseUp, at: NSPoint(x: bar.bounds.midX, y: bar.bounds.maxY - 20)))
    XCTAssertGreaterThan(document.viewportLines.first, 1_000, "トラックを押した位置へ飛ぶ")

    pane.showSearch()
    pane.search.setNeedle("value1500 ")
    XCTAssertTrue(document.waitUntilCaughtUp())
    pane.search.next()
    let (first, visible) = document.viewportLines
    XCTAssertEqual(first + visible / 2, 1500.5, accuracy: 1, "一致の行を中央に見せる")
    pane.closeSearch()
  }

  /// 再起動の復元で開く文書も、タブに渡した組成（新しい面）で開く。
  func testRestoredDocumentsOpenWithTheNewSurface() throws {
    let url = try caseFile("a.swift", lines(5))
    let state = TabState(
      cwd: "/tmp", agent: nil, explicitTitle: nil,
      editor: EditorState(open: [url.path], active: url.path))
    let tab = TerminalTab(restoring: state, resumeSpawn: { _ in nil }, editorSurfaces: surfaces)
    tab.recordMaterializationStarted()
    XCTAssertTrue(isMetal(try XCTUnwrap(tab.editor.activeDocument)))
  }

  /// 設定から面の選択までの本番の配線——`editor-engine-metal` を真にして実効設定を反映すると、新しいタブで開く文書も
  /// 再起動の復元で開く文書も新しい面になり、偽に戻して開けば今の面になる。壊れると、設定を真にしても全テストが
  /// 緑のまま今の面で開く（タブへ渡す組成が落ちても既定の組成でコンパイルが通る）。
  func testTheSettingPicksTheSurfaceThroughTheWindowController() throws {
    let a = try caseFile("a.swift", lines(5))
    let b = try caseFile("b.swift", lines(5))
    let wc = WindowController()
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.editorEngineMetal, true))
    wc.applyActiveWorkspaceConfig()
    let opened = try XCTUnwrap(
      wc.openTab(workspaceIndex: 0, cwd: a.deletingLastPathComponent().path))
    let tab = try XCTUnwrap(wc.controlResolveTab(opened.tabId))
    XCTAssertTrue(isMetal(try tab.editor.open(a)), "新しいタブで開く文書は新しい面")
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.editorEngineMetal, false))
    wc.applyActiveWorkspaceConfig()
    XCTAssertFalse(isMetal(try tab.editor.open(b)), "偽に戻して開けば今の面")

    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.editorEngineMetal, true))
    let state = TabState(
      cwd: "/tmp", agent: nil, explicitTitle: nil,
      editor: EditorState(open: [a.path], active: a.path))
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [state])])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let restored = try XCTUnwrap(WindowController().activeTab)
    restored.recordMaterializationStarted()
    XCTAssertTrue(isMetal(try XCTUnwrap(restored.editor.activeDocument)), "復元で開く文書も新しい面")
  }
}
