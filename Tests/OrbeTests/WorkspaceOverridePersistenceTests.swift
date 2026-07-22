import XCTest

@testable import Orbe

/// workspace 設定上書き層（`settingsOverride`）の永続検証（libghostty 非依存）。
/// 新形式（canonical key）の往復・欠落時の後方互換（nil）を固定する。旧 camelCase 移行は `SettingsMigrationTests`。
final class WorkspaceOverridePersistenceTests: XCTestCase {

  private func layer(_ mutate: (inout SettingsLayer) -> Void) -> SettingsLayer {
    var l = SettingsLayer()
    mutate(&l)
    return l
  }

  /// settingsOverride（あり/nil 混在）がディスク往復で保たれる。
  func testOverrideRoundTripThroughFile() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-ov-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tmp
    defer {
      WorkspacePersistence.fileURLOverride = nil
      try? FileManager.default.removeItem(at: tmp)
    }

    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "styled", rootPath: "/", activeTab: 0,
          tabs: [TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)],
          settingsOverride: layer {
            $0[SettingKeys.fontSize] = 20
            $0[SettingKeys.theme] = .dark
          }),
        WorkspaceState(
          name: "plain", rootPath: "/", activeTab: 0,
          tabs: [TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)],
          settingsOverride: nil),
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(
      WorkspacePersistence.load(), original,
      "settingsOverride（あり/nil 混在）がディスク往復で保たれる")
  }

  /// settingsOverride キーを欠いた旧 JSON（version:3）も load 成功し、settingsOverride は nil（上書き無し）。
  func testLegacyJSONWithoutOverrideLoads() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-no-ov-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tmp
    defer {
      WorkspacePersistence.fileURLOverride = nil
      try? FileManager.default.removeItem(at: tmp)
    }

    let legacy = """
      {"version":3,"activeWorkspace":0,"workspaces":[\
      {"name":"a","rootPath":"/","activeTab":0,"tabs":[{"tree":{"leaf":{}},"editor":{"open":false,"tool":"tree"}}]}]}
      """
    try Data(legacy.utf8).write(to: tmp)
    let loaded = try XCTUnwrap(
      WorkspacePersistence.load(), "settingsOverride 欠落（optional）でも load 成功")
    XCTAssertEqual(loaded.workspaces.count, 1, "workspace が健在（喪失しない）")
    XCTAssertNil(loaded.workspaces[0].settingsOverride, "欠落時 settingsOverride は nil（上書き無し）")
  }

  /// 空 override（全項目除去）は保存で nil へ畳まれる（decode 側の isEmpty 畳み込み）。
  func testEmptyOverrideFoldsToNil() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-empty-ov-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tmp
    defer {
      WorkspacePersistence.fileURLOverride = nil
      try? FileManager.default.removeItem(at: tmp)
    }
    let file = """
      {"version":3,"activeWorkspace":0,"workspaces":[\
      {"name":"a","rootPath":"/","activeTab":0,\
      "tabs":[{"tree":{"leaf":{}},"editor":{"open":false,"tool":"tree"}}],"settingsOverride":{}}]}
      """
    try Data(file.utf8).write(to: tmp)
    let loaded = try XCTUnwrap(WorkspacePersistence.load())
    XCTAssertNil(loaded.workspaces[0].settingsOverride, "空 override は nil へ畳む")
  }
}
