import XCTest

@testable import Orbe

/// workspace の「前回のベース」（`lastWorktreeBase`）の永続。壊れると、再起動のたびに作成行の初期の
/// ベースが既定に戻る・読めない値 1 つで workspace ごと失う、のどちらかになる。
final class WorkspaceWorktreeBasePersistenceTests: OrbeTestCase {

  func testRoundTripThroughFile() {
    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "a", rootPath: "/", activeTab: 0, tabs: [], lastWorktreeBase: "origin/release/0.8"),
        WorkspaceState(name: "b", rootPath: "/", activeTab: 0, tabs: []),
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(WorkspacePersistence.load(), original)
  }

  /// 項目の無い旧 JSON と、型の合わない値は「前回なし」として読み、workspace は失わない。
  func testMissingOrMalformedValueReadsAsNoPrevious() throws {
    let file = """
      {"version":4,"activeWorkspace":0,"workspaces":[\
      {"name":"a","rootPath":"/","activeTab":0,"tabs":[]},\
      {"name":"b","rootPath":"/","activeTab":0,"tabs":[],"lastWorktreeBase":42}]}
      """
    try Data(file.utf8).write(to: workspacesFile())
    let loaded = try XCTUnwrap(WorkspacePersistence.load())
    XCTAssertEqual(loaded.workspaces.map(\.name), ["a", "b"])
    XCTAssertEqual(loaded.workspaces.map(\.lastWorktreeBase), [nil, nil])
  }
}
