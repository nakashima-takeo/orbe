import XCTest

@testable import Orbe

/// 連の面の配置の永続——`workspaces.json` の `groups[].faces` の形、既定の省略、読めない値の寛容 decode。
///
/// 壊れると何が起きるか。既定を書いてしまうと、既定のままの大多数の連に冗長な既定値が積まれ、`windowSize` /
/// `lastUsedAt` / `settingsOverride` と同じ「不在 ⇔ 既定」の家風から外れる。
/// 読めない `faces` でファイルごと捨てると、1 つの連の値の破損で全 workspace の復元が消える。
/// 範囲外の割合をそのまま置くと隠れた面が焦点になり、起動直後のキーが見えない面へ届く。
extension WorkspacePersistenceTests {
  /// 配置は `{"editorRatio", "focus"}` で書き、既定（端末だけ）のときは書かない。
  func testGroupStateWritesFacesOnlyWhenNotDefault() throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    let split = try enc.encode(
      GroupState(root: "/w", faces: FaceLayout(editorRatio: 0.5, focus: .editor)))
    XCTAssertEqual(
      String(data: split, encoding: .utf8),
      #"{"faces":{"editorRatio":0.5,"focus":"editor"},"root":"/w"}"#)

    let plain = try enc.encode(GroupState(root: "/w"))
    XCTAssertEqual(String(data: plain, encoding: .utf8), #"{"root":"/w"}"#, "既定は書かない")
  }

  /// 分割と焦点の面がディスク往復で保たれる。
  func testFacesRoundTripThroughFile() {
    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "w", rootPath: "/", activeTab: 0,
          tabs: [
            TabState(cwd: "/p", agent: nil, explicitTitle: nil),
            TabState(cwd: "/q", agent: nil, explicitTitle: nil),
          ],
          groups: [GroupState(root: "/p", faces: FaceLayout(editorRatio: 0.35, focus: .editor))])
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(WorkspacePersistence.load(), original)
  }

  /// 読めない `faces`（型違い・未知の焦点）は既定（端末だけ）へ落ち、範囲外の割合は正規形に直す。根の無い要素はその要素
  /// だけを落とし、`groups` が無ければ空。ファイルの残りは失わない。
  func testUnreadableFacesFallBackToTerminalOnlyWithoutLosingTheFile() throws {
    let json = """
      {"version":\(WorkspacePersistence.version),"activeWorkspace":0,"workspaces":[\
      {"name":"w","rootPath":"/","activeTab":0,"tabs":[{"cwd":"/a"}],"groups":[\
      {"root":"/a","faces":"garbage"},\
      {"faces":{"editorRatio":0.5,"focus":"editor"}},\
      {"root":"/b","faces":{"editorRatio":0.5,"focus":"browser"}},\
      {"root":"/c","faces":{"editorRatio":1.5,"focus":"terminal"}},\
      {"root":"/d","faces":{"editorRatio":0.5,"focus":"terminal"}}]},\
      {"name":"v","rootPath":"/","activeTab":0,"tabs":[{"cwd":"/a"}]}]}
      """
    try Data(json.utf8).write(to: workspacesFile())

    let loaded = try XCTUnwrap(WorkspacePersistence.load(), "1 つの連の faces の破損でファイルを捨てない")
    XCTAssertEqual(
      loaded.workspaces[0].groups,
      [
        GroupState(root: "/a"),
        GroupState(root: "/b"),
        GroupState(root: "/c", faces: FaceLayout(editorRatio: 1, focus: .editor)),
        GroupState(root: "/d", faces: FaceLayout(editorRatio: 0.5, focus: .terminal)),
      ])
    XCTAssertEqual(loaded.workspaces[1].groups, [], "groups が無ければ空")
  }
}
