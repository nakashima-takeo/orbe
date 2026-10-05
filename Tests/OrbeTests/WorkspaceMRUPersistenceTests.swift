import XCTest

@testable import Orbe

/// MRU 並べ替え用 `lastUsedAt` の永続検証（libghostty 非依存）。
final class WorkspaceMRUPersistenceTests: OrbeTestCase {

  /// lastUsedAt（あり/nil 混在）がディスク往復で保たれる。
  func testLastUsedAtRoundTripThroughFile() {
    let stamp = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "recent", rootPath: "/", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)],
          lastUsedAt: stamp),
        WorkspaceState(
          name: "never", rootPath: "/", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)],
          lastUsedAt: nil),
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(
      WorkspacePersistence.load(), original,
      "lastUsedAt（あり/nil 混在）がディスク往復で保たれる")
  }
}
