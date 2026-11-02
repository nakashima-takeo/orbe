import XCTest

@testable import Orbe

/// workspace の ID（`Workspace.id`。制御の宛先で、タスク・自動化が workspace を指す値）を、workspaces.json から寛容に読むことを
/// 固定する。
///
/// 壊れると何が起きるか: 後から足したこの項目が無い・読めないだけでファイル全体を落とすと、更新直後の
/// 初回起動で全 workspace 構成が退避され既定構成になる。ID を振り損ねて workspace 同士で重なると、
/// 片方に付けたタスクがもう片方にも付いて見え、制御からは片方にしか届かない。往復で値が保たれることは、`WorkspacesFile` の等値で
/// 見る既存の往復テスト（`WindowControllerRestoreTests` ほか）が持つ。
final class WorkspacePersistentIdTests: OrbeTestCase {
  private func write(_ workspaces: [String], top extra: String = "") throws {
    let json =
      #"{"version":\#(WorkspacePersistence.version),"activeWorkspace":0,"#
      + #""workspaces":[\#(workspaces.joined(separator: ","))]\#(extra)}"#
    try Data(json.utf8).write(to: workspacesFile())
  }

  private func workspace(_ name: String, extra: String = "") -> String {
    #"{"name":"\#(name)","rootPath":"/tmp/\#(name)","activeTab":0,"tabs":[{"cwd":"/tmp"}]\#(extra)}"#
  }

  func testWorkspacesWithoutAPersistentIdEachGetADistinctOne() throws {
    try write([workspace("alpha"), workspace("bravo")])

    let loaded = try XCTUnwrap(WorkspacePersistence.load(), "workspace の ID が無くてもファイルは読める")

    XCTAssertEqual(loaded.workspaces.map(\.name), ["alpha", "bravo"], "workspace 構成は欠けない")
    XCTAssertNotEqual(
      loaded.workspaces[0].id, loaded.workspaces[1].id,
      "振ったworkspace の ID は workspace ごとに別")
  }

  func testUnreadablePersistentIdIsReplacedOnlyForThatWorkspace() throws {
    let kept = UUID()
    try write([
      workspace("broken", extra: #","persistentId":"oops""#),
      workspace("kept", extra: #","persistentId":"\#(kept.uuidString)""#),
    ])

    let loaded = try XCTUnwrap(
      WorkspacePersistence.load(), "1 workspace のworkspace の ID が読めなくてもファイルは読める")

    XCTAssertEqual(loaded.workspaces.map(\.name), ["broken", "kept"])
    XCTAssertEqual(loaded.workspaces[1].id, kept, "読めるworkspace の ID はそのまま保つ")
    XCTAssertNotEqual(loaded.workspaces[0].id, kept)
  }

  /// Home を指す値も同じく寛容に読む。読めなければ「無し」へ落ち、ファイル全体は失わない。
  func testHomeIdIsReadAndAnUnreadableOneFallsBackToNone() throws {
    let home = UUID()
    try write([workspace("alpha")], top: #","homeWorkspaceId":"\#(home.uuidString)""#)
    XCTAssertEqual(try XCTUnwrap(WorkspacePersistence.load()).homeWorkspaceId, home)

    try write([workspace("alpha")], top: #","homeWorkspaceId":42"#)
    let loaded = try XCTUnwrap(WorkspacePersistence.load(), "読めない値でもファイルは読める")
    XCTAssertNil(loaded.homeWorkspaceId)
    XCTAssertEqual(loaded.workspaces.map(\.name), ["alpha"])
  }
}
