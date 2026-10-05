import XCTest

@testable import Orbe

/// workspace 設定上書き層（`settingsOverride`）の永続検証（libghostty 非依存）。
/// 新形式（canonical key）の往復と、1 キーの異常で層ごと失わないことを固定する。旧 camelCase 移行は `SettingsMigrationTests`。
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
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)],
          settingsOverride: layer {
            $0[SettingKeys.fontSize] = 20
            $0[SettingKeys.theme] = .dark
          }),
        WorkspaceState(
          name: "plain", rootPath: "/", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)],
          settingsOverride: nil),
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(
      WorkspacePersistence.load(), original,
      "settingsOverride（あり/nil 混在）がディスク往復で保たれる")
  }

  /// workspaces.json に 1 workspace ＋ 生の settingsOverride を書く（異常キー混在の fixture 用）。
  private func writeOverrideJSON(_ override: String) throws {
    let file = """
      {"version":4,"activeWorkspace":0,"workspaces":[\
      {"name":"a","rootPath":"/","activeTab":0,"tabs":[{"cwd":"/"}],\
      "settingsOverride":\(override)}]}
      """
    try Data(file.utf8).write(to: workspacesFile())
  }

  /// 新形式 override に型不一致の既知キーや未知キー（新しい版で足され、古い版へ戻った時に残っている項目）が
  /// 混ざっても、健全な他項目は生き残る。層ごと失うと `isEmpty` 畳み込みで nil になり、次の save で
  /// ディスクからも上書き消滅する——1 キーの異常やロールバックだけで workspace の見た目設定が丸ごと消える。
  func testOverrideWithTypeMismatchOrUnknownKeyKeepsOtherKeys() throws {
    try writeOverrideJSON(
      #"{"font-size":"oops","future-setting":1,"theme":"dark","default-agent":"codex"}"#)
    let loaded = try XCTUnwrap(WorkspacePersistence.load())
    let override = try XCTUnwrap(loaded.workspaces[0].settingsOverride, "層ごと消えず上書きは残る")
    XCTAssertNil(override[SettingKeys.fontSize], "型不一致の font-size だけが落ちる")
    XCTAssertEqual(override[SettingKeys.theme], .dark, "健全な他項目は生存する")
    XCTAssertEqual(override[SettingKeys.defaultAgent], "codex", "健全な他項目は生存する")
  }
}
