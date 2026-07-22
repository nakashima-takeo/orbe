import XCTest

@testable import Orbe

/// タブ単位の EditorPane 画面状態（TabState.editor）の永続往復。
/// MRU・override と同様、粗粒度フィールドの save→load 往復を個別に固定する。
final class WorkspaceEditorPersistenceTests: XCTestCase {

  /// editor の開閉・ツール（非既定値）がディスク往復で保たれる。
  func testEditorTabStateRoundTripThroughFile() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-editor-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tmp
    defer {
      WorkspacePersistence.fileURLOverride = nil
      try? FileManager.default.removeItem(at: tmp)
    }

    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "w", rootPath: "/", activeTab: 0,
          tabs: [
            TabState(
              tree: .leaf(cwd: "/p", agent: nil), explicitTitle: nil,
              editor: EditorPaneTabState(open: true, tool: "git")),
            TabState(tree: .leaf(cwd: "/q", agent: nil), explicitTitle: nil),
          ])
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(
      WorkspacePersistence.load(), original,
      "editor（open:true/tool:git）と既定 editor の混在がディスク往復で保たれる")
  }
}
