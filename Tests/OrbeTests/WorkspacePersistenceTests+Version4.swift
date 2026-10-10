import OrbeEditorCore
import XCTest

@testable import Orbe

/// version 4（タブごとの面の配置とエディターの状態）からの移行——読みはタブごとの旧い値を移行専用に添えるだけで、連ごとの
/// 集約は復元が `groupStates` で行う。配置・焦点の文書・仮・検索の問いは連のアクティブなタブ（無ければ保存順で最初に状態を
/// 持つタブ）のもの、文書の列は連の全タブを保存順に重複なく合わせたもの。version 5 はキーの一致する `groups` だけを採る。
///
/// 壊れると何が起きるか。更新した最初の起動で、開いていた文書と分割が全部消える。同じ連の別のタブで開いていた文書だけが
/// 消える。根の変わった連の状態が別の連へ紛れ込む。移行専用の値が書き戻されて version 5 のファイルに旧い形が残る。
extension WorkspacePersistenceTests {
  private func version4(_ tabs: String, activeTab: Int = 0) -> String {
    """
    {"version":4,"activeWorkspace":0,"workspaces":[\
    {"name":"w","rootPath":"/","activeTab":\(activeTab),"tabs":[\(tabs)]}]}
    """
  }

  func testVersion4TabsCarryTheirOldLayoutOnlyForMigration() throws {
    let tabs = [
      #"{"cwd":"/a","faces":{"editorRatio":0.5,"focus":"editor"},"#
        + #""editor":{"open":["/a/x"],"active":"/a/x"}}"#,
      #"{"cwd":"/b"}"#,
    ].joined(separator: ",")
    try Data(version4(tabs).utf8).write(to: workspacesFile())

    let loaded = try XCTUnwrap(WorkspacePersistence.load())
    let loadedTabs = loaded.workspaces[0].tabs
    XCTAssertEqual(
      loadedTabs[0].version4,
      TabState.Version4(
        faces: FaceLayout(editorRatio: 0.5, focus: .editor),
        editor: EditorState(documents: .init(open: ["/a/x"], active: "/a/x"))))
    XCTAssertEqual(loadedTabs[1].version4, TabState.Version4(faces: .terminalOnly, editor: nil))

    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    XCTAssertEqual(
      String(data: try enc.encode(loadedTabs[0]), encoding: .utf8), #"{"cwd":"/a"}"#, "移行専用の値は書かない")
  }

  /// 連のアクティブなタブの配置と焦点の文書を採り、文書の列は連の全タブを保存順に重複なく合わせる。
  func testVersion4AggregatesEachGroupFromItsActiveTab() throws {
    let tabs = [
      #"{"cwd":"/r","faces":{"editorRatio":0.3,"focus":"terminal"},"#
        + #""editor":{"open":["/r/a","/r/b"],"active":"/r/a"}}"#,
      #"{"cwd":"/r/sub","faces":{"editorRatio":1,"focus":"editor"},"#
        + #""editor":{"open":["/r/b","/r/c"],"active":"/r/c","preview":"/r/c","#
        + #""search":{"pattern":"q"}}}"#,
      #"{"cwd":"/s","editor":{"open":["/s/z"],"active":"/s/z"}}"#,
    ].joined(separator: ",")
    try Data(version4(tabs, activeTab: 1).utf8).write(to: workspacesFile())
    let state = try XCTUnwrap(WorkspacePersistence.load()).workspaces[0]

    let groups = state.groupStates(keys: ["/r", "/r", "/s"])

    XCTAssertEqual(
      groups["/r"],
      GroupState(
        root: "/r", faces: FaceLayout(editorRatio: 1, focus: .editor),
        editor: EditorState(
          documents: .init(open: ["/r/a", "/r/b", "/r/c"], active: "/r/c", preview: "/r/c"),
          search: SearchQuery(pattern: "q"))))
    XCTAssertEqual(
      groups["/s"],
      GroupState(root: "/s", editor: EditorState(documents: .init(open: ["/s/z"], active: "/s/z"))),
      "アクティブなタブの無い連は、保存順で最初に状態を持つタブのもの")
  }

  /// アクティブなタブの無い連は、保存順で最初に状態を持つタブ（既定の配置で文書の無いタブは飛ばす）の配置を採る。
  /// 集約して既定のままの連は載せない。
  func testVersion4WithoutAnActiveTabTakesTheFirstTabWithState() throws {
    let tabs = [
      #"{"cwd":"/x"}"#,
      #"{"cwd":"/r"}"#,
      #"{"cwd":"/r","faces":{"editorRatio":0.6,"focus":"editor"}}"#,
      #"{"cwd":"/r","faces":{"editorRatio":1,"focus":"editor"}}"#,
    ].joined(separator: ",")
    try Data(version4(tabs, activeTab: 0).utf8).write(to: workspacesFile())
    let state = try XCTUnwrap(WorkspacePersistence.load()).workspaces[0]

    let groups = state.groupStates(keys: ["/x", "/r", "/r", "/r"])

    XCTAssertNil(groups["/x"], "既定のままの連は載せない")
    XCTAssertEqual(
      groups["/r"], GroupState(root: "/r", faces: FaceLayout(editorRatio: 0.6, focus: .editor)))
  }

  /// version 5 はキーの一致する `groups` を採り、キーの合わない状態は捨てる。
  func testVersion5TakesGroupsWhoseRootMatchesAKey() {
    let state = WorkspaceState(
      name: "w", rootPath: "/", activeTab: 0,
      tabs: [TabState(cwd: "/a", agent: nil, explicitTitle: nil)],
      groups: [
        GroupState(root: "/a", faces: FaceLayout(editorRatio: 1, focus: .editor)),
        GroupState(root: "/gone", faces: FaceLayout(editorRatio: 0.5, focus: .editor)),
      ])

    XCTAssertEqual(
      state.groupStates(keys: ["/a"]),
      ["/a": GroupState(root: "/a", faces: FaceLayout(editorRatio: 1, focus: .editor))])
  }
}
