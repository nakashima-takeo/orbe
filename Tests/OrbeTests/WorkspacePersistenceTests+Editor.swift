import XCTest

@testable import Orbe

/// 開いていた文書の永続——`tabs[].editor` の形、無いときの省略、読めない値の寛容 decode、
/// そして「フィールドを足して encode / decode を忘れる」を検出する全キーの往復。
///
/// 壊れると何が起きるか。再起動で開いていたファイルが戻らない。1 タブの editor の破損で全 workspace の復元が
/// 消える。新しいフィールドが片方だけに書かれて黙って落ちる。
extension WorkspacePersistenceTests {
  func testTabStateWritesEditorOnlyWhenDocumentsAreOpen() throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let opened = try enc.encode(
      TabState(
        cwd: "/w", agent: nil, explicitTitle: nil,
        editor: EditorState(open: ["/w/a.swift", "/w/b.md"], active: "/w/b.md")))
    XCTAssertEqual(
      String(data: opened, encoding: .utf8),
      #"{"cwd":"/w","editor":{"active":"/w/b.md","open":["/w/a.swift","/w/b.md"]}}"#)
    let empty = try enc.encode(
      TabState(cwd: "/w", agent: nil, explicitTitle: nil, editor: EditorState(open: [], active: ""))
    )
    XCTAssertEqual(String(data: empty, encoding: .utf8), #"{"cwd":"/w"}"#, "空なら書かない")
  }

  func testUnreadableEditorFallsBackToNilWithoutLosingTheFile() throws {
    let json = """
      {"version":\(WorkspacePersistence.version),"activeWorkspace":0,"workspaces":[\
      {"name":"w","rootPath":"/","activeTab":0,"tabs":[\
      {"cwd":"/a","editor":"garbage"},\
      {"cwd":"/b","editor":{"open":["/b/x"]}},\
      {"cwd":"/c","editor":{"open":[],"active":""}},\
      {"cwd":"/d","editor":{"open":["/d/x"],"active":"/d/x"}}]}]}
      """
    try Data(json.utf8).write(to: workspacesFile())
    let loaded = try XCTUnwrap(WorkspacePersistence.load())
    let tabs = loaded.workspaces[0].tabs
    XCTAssertNil(tabs[0].editor, "型違いは nil")
    XCTAssertNil(tabs[1].editor, "active 欠落は nil")
    XCTAssertNil(tabs[2].editor, "空の列は nil")
    XCTAssertEqual(tabs[3].editor, EditorState(open: ["/d/x"], active: "/d/x"))
  }

  /// 全フィールドを非既定にした TabState は、全キーが JSON に現れ、往復で等しい。
  func testEveryCodingKeyRoundTrips() throws {
    let full = TabState(
      cwd: "/w", agent: AgentSession(command: "claude", sessionId: "s-1"), explicitTitle: "t",
      faces: FaceLayout(editorRatio: 0.4, focus: .editor),
      editor: EditorState(open: ["/w/a"], active: "/w/a"))
    let data = try JSONEncoder().encode(full)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in TabState.CodingKeys.allCases {
      XCTAssertNotNil(object[key.rawValue], "\(key) が encode に現れない")
    }
    XCTAssertEqual(try JSONDecoder().decode(TabState.self, from: data), full)
  }
}
