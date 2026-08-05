import XCTest

@testable import Orbe

/// workspace 設定上書き層（`settingsOverride`）の永続検証（libghostty 非依存）。
/// 新形式（canonical key）の往復・欠落時の後方互換（nil）を固定する。旧 camelCase 移行は `SettingsMigrationTests`。
final class WorkspaceOverridePersistenceTests: OrbeTestCase {

  private func layer(_ mutate: (inout SettingsLayer) -> Void) -> SettingsLayer {
    var l = SettingsLayer()
    mutate(&l)
    return l
  }

  /// settingsOverride（あり/nil 混在）がディスク往復で保たれる。
  func testOverrideRoundTripThroughFile() {
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
    let tmp = try XCTUnwrap(WorkspacePersistence.fileURL)
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

  /// workspaces.json に 1 workspace ＋ 生の settingsOverride を書く（異常キー混在の fixture 用）。
  private func writeOverrideJSON(_ override: String) throws {
    let file = """
      {"version":3,"activeWorkspace":0,"workspaces":[\
      {"name":"a","rootPath":"/","activeTab":0,\
      "tabs":[{"tree":{"leaf":{}},"editor":{"open":false,"tool":"tree"}}],\
      "settingsOverride":\(override)}]}
      """
    try Data(file.utf8).write(to: workspacesFile())
  }

  /// 新形式 override の既知キー 1 件が型不一致でも、健全な他項目は生き残る。
  /// 層ごと失うと `isEmpty` 畳み込みで nil になり、次の save でディスクからも上書き消滅する
  /// ——1 キーの異常で workspace の見た目設定が丸ごと消える事故になる（global 層と同じ寛容さで守る）。
  func testOverrideWithOneTypeMismatchKeepsOtherKeys() throws {
    try writeOverrideJSON(#"{"font-size":"oops","theme":"dark","default-agent":"codex"}"#)
    let loaded = try XCTUnwrap(WorkspacePersistence.load())
    let override = try XCTUnwrap(loaded.workspaces[0].settingsOverride, "層ごと消えず上書きは残る")
    XCTAssertNil(override[SettingKeys.fontSize], "型不一致の font-size だけが落ちる")
    XCTAssertEqual(override[SettingKeys.theme], .dark, "健全な他項目は生存する")
    XCTAssertEqual(override[SettingKeys.defaultAgent], "codex", "健全な他項目は生存する")
  }

  /// 新形式 override に未知キー（新しい版で足され、古い版へ戻った時に残っている項目）が混ざっても、
  /// 既知の項目は読める。未知キーで層ごと捨てると、ロールバックしただけで上書きが消える。
  func testOverrideWithUnknownKeyKeepsKnownKeys() throws {
    try writeOverrideJSON(#"{"future-setting":1,"font-size":18,"theme":"dark"}"#)
    let loaded = try XCTUnwrap(WorkspacePersistence.load())
    let override = try XCTUnwrap(loaded.workspaces[0].settingsOverride, "層ごと消えず上書きは残る")
    XCTAssertEqual(override[SettingKeys.fontSize], 18, "未知キー混在でも既知の項目は読める")
    XCTAssertEqual(override[SettingKeys.theme], .dark, "未知キー混在でも既知の項目は読める")
  }

  /// 空 override（全項目除去）は保存で nil へ畳まれる（decode 側の isEmpty 畳み込み）。
  func testEmptyOverrideFoldsToNil() throws {
    let tmp = try XCTUnwrap(WorkspacePersistence.fileURL)
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
