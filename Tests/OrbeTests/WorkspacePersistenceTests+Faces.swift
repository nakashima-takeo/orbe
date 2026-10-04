import XCTest

@testable import Orbe

/// タブの面の配置の永続——`workspaces.json` の `tabs[].faces` の形、既定の省略、読めない値の寛容 decode。
///
/// 壊れると何が起きるか。既定を書いてしまうと、既定のままの大多数のタブに冗長な既定値が積まれ、`windowSize` /
/// `lastUsedAt` / `settingsOverride` と同じ「不在 ⇔ 既定」の家風から外れる。
/// 読めない `faces` でファイルごと捨てると、1 タブの値の破損で全 workspace の復元が消える。
/// 範囲外の割合をそのまま置くと隠れた面が焦点になり、起動直後のキーが見えない面へ届く。
extension WorkspacePersistenceTests {
  /// 配置は `{"editorRatio", "focus"}` で書き、既定（端末だけ）のときは書かない。
  func testTabStateWritesFacesOnlyWhenNotDefault() throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    let split = try enc.encode(
      TabState(
        cwd: "/w", agent: nil, explicitTitle: nil,
        faces: FaceLayout(editorRatio: 0.5, focus: .editor)))
    XCTAssertEqual(
      String(data: split, encoding: .utf8),
      #"{"cwd":"/w","faces":{"editorRatio":0.5,"focus":"editor"}}"#)

    let plain = try enc.encode(TabState(cwd: "/w", agent: nil, explicitTitle: nil))
    XCTAssertEqual(String(data: plain, encoding: .utf8), #"{"cwd":"/w"}"#, "既定は書かない")
  }

  /// 分割と焦点の面がディスク往復で保たれる。
  func testFacesRoundTripThroughFile() {
    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "w", rootPath: "/", activeTab: 0,
          tabs: [
            TabState(
              cwd: "/p", agent: nil, explicitTitle: nil,
              faces: FaceLayout(editorRatio: 0.35, focus: .editor)),
            TabState(cwd: "/q", agent: nil, explicitTitle: nil),
          ])
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(WorkspacePersistence.load(), original)
  }

  /// 読めない `faces`（型違い・未知の焦点）は既定（端末だけ）へ落ち、範囲外の割合は正規形に直す。
  /// タブの他の項目とファイルの残りは失わない。
  func testUnreadableFacesFallBackToTerminalOnlyWithoutLosingTheFile() throws {
    let json = """
      {"version":\(WorkspacePersistence.version),"activeWorkspace":0,"workspaces":[\
      {"name":"w","rootPath":"/","activeTab":2,"tabs":[\
      {"cwd":"/a","explicitTitle":"a","faces":"garbage"},\
      {"cwd":"/b","faces":{"editorRatio":0.5,"focus":"browser"}},\
      {"cwd":"/c","faces":{"editorRatio":1.5,"focus":"terminal"}},\
      {"cwd":"/d","faces":{"editorRatio":0.5,"focus":"terminal"}}]}]}
      """
    try Data(json.utf8).write(to: workspacesFile())

    let loaded = try XCTUnwrap(WorkspacePersistence.load(), "1 タブの faces の破損でファイルを捨てない")
    XCTAssertEqual(
      loaded.workspaces[0].tabs,
      [
        TabState(cwd: "/a", agent: nil, explicitTitle: "a"),
        TabState(cwd: "/b", agent: nil, explicitTitle: nil),
        TabState(
          cwd: "/c", agent: nil, explicitTitle: nil,
          faces: FaceLayout(editorRatio: 1, focus: .editor)),
        TabState(
          cwd: "/d", agent: nil, explicitTitle: nil,
          faces: FaceLayout(editorRatio: 0.5, focus: .terminal)),
      ])
    XCTAssertEqual(loaded.workspaces[0].activeTab, 2, "ファイルの残りは保たれる")
  }
}
