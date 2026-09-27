import OrbeEditorCore
import XCTest

@testable import Orbe

/// 開いていた文書の永続——`tabs[].editor` の形、無いときの省略、読めない値の寛容 decode、
/// そして「フィールドを足して encode / decode を忘れる」を検出する全キーの往復。
///
/// 壊れると何が起きるか。再起動で開いていたファイルが戻らない。1 タブの editor の破損で全 workspace の復元が
/// 消える。新しいフィールドが片方だけに書かれて黙って落ちる。
extension WorkspacePersistenceTests {
  func testTabStateWritesEditorOnlyWhenItHasState() throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let opened = try enc.encode(
      TabState(
        cwd: "/w", agent: nil, explicitTitle: nil,
        editor: EditorState(documents: .init(open: ["/w/a.swift", "/w/b.md"], active: "/w/b.md"))))
    XCTAssertEqual(
      String(data: opened, encoding: .utf8),
      #"{"cwd":"/w","editor":{"active":"/w/b.md","open":["/w/a.swift","/w/b.md"]}}"#)
    let empty = try enc.encode(
      TabState(cwd: "/w", agent: nil, explicitTitle: nil, editor: EditorState())
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
    XCTAssertEqual(tabs[3].editor, EditorState(documents: .init(open: ["/d/x"], active: "/d/x")))
  }

  /// 全フィールドを非既定にした TabState は、全キーが JSON に現れ、往復で等しい。
  func testEveryCodingKeyRoundTrips() throws {
    let full = TabState(
      cwd: "/w", agent: AgentSession(command: "claude", sessionId: "s-1"), explicitTitle: "t",
      faces: FaceLayout(editorRatio: 0.4, focus: .editor),
      editor: EditorState(
        documents: .init(open: ["/w/a"], active: "/w/a"),
        search: SearchQuery(pattern: "p", matchCase: true, wholeWord: true, isRegex: true)))
    let data = try JSONEncoder().encode(full)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in TabState.CodingKeys.allCases {
      XCTAssertNotNil(object[key.rawValue], "\(key) が encode に現れない")
    }
    let editor = try XCTUnwrap(object["editor"] as? [String: Any])
    for key in EditorState.CodingKeys.allCases {
      XCTAssertNotNil(editor[key.rawValue], "editor.\(key) が encode に現れない")
    }
    XCTAssertEqual(try JSONDecoder().decode(TabState.self, from: data), full)
  }

  /// 検索の問いだけのエディターの状態も書き、文書と問いは互いに独立に読めなければ落とす（既定へ）。
  func testTheSearchQueryIsWrittenAndReadIndependentlyOfTheDocuments() throws {
    let query = SearchQuery(pattern: "needle", isRegex: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let written = try enc.encode(
      TabState(cwd: "/w", agent: nil, explicitTitle: nil, editor: EditorState(search: query)))
    XCTAssertEqual(
      String(data: written, encoding: .utf8),
      #"{"cwd":"/w","editor":{"search":{"isRegex":true,"matchCase":false,"pattern":"needle","wholeWord":false}}}"#
    )

    let search = #"{"pattern":"needle","isRegex":true}"#
    let json = """
      {"version":\(WorkspacePersistence.version),"activeWorkspace":0,"workspaces":[\
      {"name":"w","rootPath":"/","activeTab":0,"tabs":[\
      {"cwd":"/a","editor":{"search":\(search)}},\
      {"cwd":"/b","editor":{"open":"garbage","search":\(search)}},\
      {"cwd":"/c","editor":{"open":["/c/x"],"active":"/c/x","search":"garbage"}}]}]}
      """
    try Data(json.utf8).write(to: workspacesFile())
    let tabs = try XCTUnwrap(WorkspacePersistence.load()).workspaces[0].tabs
    XCTAssertEqual(tabs[0].editor, EditorState(search: query), "問いだけでも戻る")
    XCTAssertEqual(tabs[1].editor, EditorState(search: query), "読めない文書は問いを巻き込まない")
    XCTAssertEqual(
      tabs[2].editor, EditorState(documents: .init(open: ["/c/x"], active: "/c/x")),
      "読めない問いは既定へ（文書は残る）")
  }
}
