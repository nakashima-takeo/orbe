import XCTest

@testable import Orbe

/// workspace の永続 ID（タスクが workspace を指すための内部の値）を、workspaces.json から寛容に読むことを固定する。
///
/// 壊れると何が起きるか: 後から足したこの項目が無い・読めないだけでファイル全体を落とすと、更新直後の
/// 初回起動で全 workspace 構成が退避され既定構成になる。ID を振り損ねて workspace 同士で重なると、
/// 片方に付けたタスクがもう片方にも付いて見える。往復で値が保たれることは、`WorkspacesFile` の等値で
/// 見る既存の往復テスト（`WindowControllerRestoreTests` ほか）が持つ。
final class WorkspacePersistentIdTests: OrbeTestCase {
  private func write(_ workspaces: [String]) throws {
    let json =
      #"{"version":4,"activeWorkspace":0,"workspaces":[\#(workspaces.joined(separator: ","))]}"#
    try Data(json.utf8).write(to: workspacesFile())
  }

  private func workspace(_ name: String, extra: String = "") -> String {
    #"{"name":"\#(name)","rootPath":"/tmp/\#(name)","activeTab":0,"tabs":[{"cwd":"/tmp"}]\#(extra)}"#
  }

  func testWorkspacesWithoutAPersistentIdEachGetADistinctOne() throws {
    try write([workspace("alpha"), workspace("bravo")])

    let loaded = try XCTUnwrap(WorkspacePersistence.load(), "永続 ID が無くてもファイルは読める")

    XCTAssertEqual(loaded.workspaces.map(\.name), ["alpha", "bravo"], "workspace 構成は欠けない")
    XCTAssertNotEqual(
      loaded.workspaces[0].persistentId, loaded.workspaces[1].persistentId,
      "振った永続 ID は workspace ごとに別")
  }

  func testUnreadablePersistentIdIsReplacedOnlyForThatWorkspace() throws {
    let kept = UUID()
    try write([
      workspace("broken", extra: #","persistentId":"oops""#),
      workspace("kept", extra: #","persistentId":"\#(kept.uuidString)""#),
    ])

    let loaded = try XCTUnwrap(WorkspacePersistence.load(), "1 workspace の永続 ID が読めなくてもファイルは読める")

    XCTAssertEqual(loaded.workspaces.map(\.name), ["broken", "kept"])
    XCTAssertEqual(loaded.workspaces[1].persistentId, kept, "読める永続 ID はそのまま保つ")
    XCTAssertNotEqual(loaded.workspaces[0].persistentId, kept)
  }
}
