import OrbeEditorCore
import XCTest

@testable import Orbe

/// 開いていた文書の永続——`groups[].editor` の形、無いときの省略、読めない値の寛容 decode（仮のタブが読めなければ仮無しへ）、
/// そして「フィールドを足して encode / decode を忘れる」を検出する全キーの往復。
///
/// 壊れると何が起きるか。再起動で開いていたファイルが戻らない。1 つの連の editor の破損で全 workspace の復元が
/// 消える。仮のタブの項目が壊れただけで開いていた文書が戻らない。新しいフィールドが片方だけに書かれて黙って落ちる。
extension WorkspacePersistenceTests {
  func testGroupStateWritesEditorOnlyWhenItHasState() throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let opened = try enc.encode(
      GroupState(
        root: "/w",
        editor: EditorState(documents: .init(open: ["/w/a.swift", "/w/b.md"], active: "/w/b.md"))))
    XCTAssertEqual(
      String(data: opened, encoding: .utf8),
      #"{"editor":{"active":"/w/b.md","open":["/w/a.swift","/w/b.md"]},"root":"/w"}"#)
    let empty = try enc.encode(GroupState(root: "/w", editor: EditorState()))
    XCTAssertEqual(String(data: empty, encoding: .utf8), #"{"root":"/w"}"#, "空なら書かない")
  }

  func testUnreadableEditorFallsBackToNilWithoutLosingTheFile() throws {
    let json = """
      {"version":\(WorkspacePersistence.version),"activeWorkspace":0,"workspaces":[\
      {"name":"w","rootPath":"/","activeTab":0,"tabs":[{"cwd":"/a"}],"groups":[\
      {"root":"/a","editor":"garbage"},\
      {"root":"/b","editor":{"open":["/b/x"]}},\
      {"root":"/c","editor":{"open":[],"active":""}},\
      {"root":"/d","editor":{"open":["/d/x"],"active":"/d/x"}},\
      {"root":"/e","editor":{"open":["/e/x"],"active":"/e/x","preview":7}},\
      {"root":"/f","editor":{"open":["/f/x","/f/y"],"active":"/f/x","preview":"/f/y"}}]}]}
      """
    try Data(json.utf8).write(to: workspacesFile())
    let loaded = try XCTUnwrap(WorkspacePersistence.load())
    let groups = loaded.workspaces[0].groups
    XCTAssertNil(groups[0].editor, "型違いは nil")
    XCTAssertNil(groups[1].editor, "active 欠落は nil")
    XCTAssertNil(groups[2].editor, "空の列は nil")
    XCTAssertEqual(groups[3].editor, EditorState(documents: .init(open: ["/d/x"], active: "/d/x")))
    XCTAssertEqual(
      groups[4].editor, EditorState(documents: .init(open: ["/e/x"], active: "/e/x")),
      "読めない仮のタブは仮無し（列とアクティブは残る）")
    XCTAssertEqual(
      groups[5].editor,
      EditorState(documents: .init(open: ["/f/x", "/f/y"], active: "/f/x", preview: "/f/y")))
  }

  /// 全フィールドを非既定にした TabState・GroupState は、全キーが JSON に現れ、往復で等しい。
  func testEveryCodingKeyRoundTrips() throws {
    let tab = TabState(
      cwd: "/w", agent: AgentSession(command: "claude", sessionId: "s-1"), explicitTitle: "t")
    let tabData = try JSONEncoder().encode(tab)
    let tabObject = try XCTUnwrap(JSONSerialization.jsonObject(with: tabData) as? [String: Any])
    for key in TabState.CodingKeys.allCases {
      XCTAssertNotNil(tabObject[key.rawValue], "\(key) が encode に現れない")
    }
    XCTAssertEqual(try JSONDecoder().decode(TabState.self, from: tabData), tab)

    let group = GroupState(
      root: "/w", faces: FaceLayout(editorRatio: 0.4, focus: .editor),
      editor: EditorState(
        documents: .init(open: ["/w/a"], active: "/w/a", preview: "/w/a"),
        search: SearchQuery(pattern: "p", matchCase: true, wholeWord: true, isRegex: true)))
    let data = try JSONEncoder().encode(group)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in GroupState.CodingKeys.allCases {
      XCTAssertNotNil(object[key.rawValue], "\(key) が encode に現れない")
    }
    let editor = try XCTUnwrap(object["editor"] as? [String: Any])
    for key in EditorState.CodingKeys.allCases {
      XCTAssertNotNil(editor[key.rawValue], "editor.\(key) が encode に現れない")
    }
    XCTAssertEqual(try JSONDecoder().decode(GroupState.self, from: data), group)
  }

  /// 検索の問いだけのエディターの状態も書き、文書と問いは互いに独立に読めなければ落とす（既定へ）。
  func testTheSearchQueryIsWrittenAndReadIndependentlyOfTheDocuments() throws {
    let query = SearchQuery(pattern: "needle", isRegex: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let written = try enc.encode(GroupState(root: "/w", editor: EditorState(search: query)))
    XCTAssertEqual(
      String(data: written, encoding: .utf8),
      #"{"editor":{"search":{"isRegex":true,"matchCase":false,"pattern":"needle","wholeWord":false}},"root":"/w"}"#
    )

    let search = #"{"pattern":"needle","isRegex":true}"#
    let json = """
      {"version":\(WorkspacePersistence.version),"activeWorkspace":0,"workspaces":[\
      {"name":"w","rootPath":"/","activeTab":0,"tabs":[{"cwd":"/a"}],"groups":[\
      {"root":"/a","editor":{"search":\(search)}},\
      {"root":"/b","editor":{"open":"garbage","search":\(search)}},\
      {"root":"/c","editor":{"open":["/c/x"],"active":"/c/x","search":"garbage"}}]}]}
      """
    try Data(json.utf8).write(to: workspacesFile())
    let groups = try XCTUnwrap(WorkspacePersistence.load()).workspaces[0].groups
    XCTAssertEqual(groups[0].editor, EditorState(search: query), "問いだけでも戻る")
    XCTAssertEqual(groups[1].editor, EditorState(search: query), "読めない文書は問いを巻き込まない")
    XCTAssertEqual(
      groups[2].editor, EditorState(documents: .init(open: ["/c/x"], active: "/c/x")),
      "読めない問いは既定へ（文書は残る）")
  }
}
