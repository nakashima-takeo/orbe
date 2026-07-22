import XCTest

@testable import Orbe

/// MRU 並べ替え用 `lastUsedAt` の永続検証（libghostty 非依存）。
/// 往復で保たれること・旧 JSON（フィールド欠落）でも後方互換で load 成功し nil になることを固定する。
final class WorkspaceMRUPersistenceTests: XCTestCase {

  /// lastUsedAt（あり/nil 混在）がディスク往復で保たれる。
  func testLastUsedAtRoundTripThroughFile() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-mru-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tmp
    defer {
      WorkspacePersistence.fileURLOverride = nil
      try? FileManager.default.removeItem(at: tmp)
    }

    let stamp = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "recent", rootPath: "/", activeTab: 0,
          tabs: [TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)],
          lastUsedAt: stamp),
        WorkspaceState(
          name: "never", rootPath: "/", activeTab: 0,
          tabs: [TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)],
          lastUsedAt: nil),
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(
      WorkspacePersistence.load(), original,
      "lastUsedAt（あり/nil 混在）がディスク往復で保たれる")
  }

  /// lastUsedAt キーを欠いた旧 JSON（version:3）も load 成功し、lastUsedAt は nil（最古扱い）。
  /// optional でなければ decode 失敗 → load nil → 全 workspace 喪失するため、後方互換の生命線。
  func testLegacyJSONWithoutLastUsedAtLoads() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-no-mru-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tmp
    defer {
      WorkspacePersistence.fileURLOverride = nil
      try? FileManager.default.removeItem(at: tmp)
    }

    let legacy = """
      {"version":3,"activeWorkspace":0,"workspaces":[\
      {"name":"a","rootPath":"/","activeTab":0,"tabs":[{"tree":{"leaf":{}},"editor":{"open":false,"tool":"tree"}}]},\
      {"name":"b","rootPath":"/","activeTab":0,"tabs":[{"tree":{"leaf":{}},"editor":{"open":false,"tool":"tree"}}]}]}
      """
    try Data(legacy.utf8).write(to: tmp)
    let loaded = try XCTUnwrap(
      WorkspacePersistence.load(), "lastUsedAt 欠落（optional）でも load 成功")
    XCTAssertEqual(loaded.workspaces.count, 2, "全 workspace が健在（喪失しない）")
    XCTAssertNil(loaded.workspaces[0].lastUsedAt, "欠落時 lastUsedAt は nil（最古扱い）")
    XCTAssertNil(loaded.workspaces[1].lastUsedAt, "欠落時 lastUsedAt は nil（最古扱い）")
  }
}
