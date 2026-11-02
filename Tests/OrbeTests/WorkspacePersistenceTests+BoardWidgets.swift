import XCTest

@testable import Orbe

/// ボードのウィジェットの並びの保存の読み書き。決めた並びだけを書き、読めない並びはその欄だけ既定へ落とす。
///
/// 壊れると何が起きるか: 外したウィジェットが再起動で戻る（空にした並びが既定と区別されない）。知らない種類 1 つや欄の型違いで
/// workspaces.json ごと退避され、全構成が既定に戻る。読めないのに空として読み、Home のボードが黙って空になる。
extension WorkspacePersistenceTests {
  /// 決めていない並びは書かず、決めた並びは空でも書く（空と既定を区別する）。
  func testBoardWidgetsAreWrittenOnlyWhenDecided() throws {
    func written(_ widgets: [BoardWidget]?) throws -> Any? {
      let state = WorkspaceState(
        name: "w", rootPath: "/w", activeTab: 0, tabs: [], boardWidgets: widgets)
      let data = try JSONEncoder().encode(state)
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])[
        "boardWidgets"]
    }
    XCTAssertNil(try written(nil))
    XCTAssertEqual((try written([]) as? [Any])?.count, 0)
    XCTAssertEqual(try written([.automation]) as? [[String: String]], [["kind": "automation"]])
  }

  /// 欄は寛容に読む: 読めない要素だけ落とし、中身があるのに 1 つも読めない・配列でないなら決めていない（既定）、`[]` だけが
  /// 決めた空。どの場合も workspace は失わない。
  func testUnreadableBoardWidgetsFallBackToUndecidedWithoutLosingTheFile() throws {
    struct Case {
      let raw: String
      let expected: [BoardWidget]?
      let label: String
    }
    let cases = [
      Case(raw: "[]", expected: [], label: "決めた空"),
      Case(
        raw: #"[{"kind":"automation"},{"kind":"weather"},{"kind":"automation"}]"#,
        expected: [.automation, .automation], label: "知らない種類だけ落とす（重なりは SessionStore.load が落とす）"),
      Case(raw: #"[{"kind":"weather"}]"#, expected: nil, label: "1 つも読めなければ既定"),
      Case(raw: #"[1, "automation"]"#, expected: nil, label: "要素の型違い"),
      Case(raw: #""automation""#, expected: nil, label: "配列でない"),
      Case(raw: "null", expected: nil, label: "null"),
    ]
    for item in cases {
      let file = """
        {"version":\(WorkspacePersistence.version),"activeWorkspace":0,"workspaces":[\
        {"name":"a","rootPath":"/","activeTab":0,"tabs":[],"boardWidgets":\(item.raw)}]}
        """
      try Data(file.utf8).write(to: workspacesFile())
      let loaded = try XCTUnwrap(WorkspacePersistence.load(), item.label)
      XCTAssertEqual(loaded.workspaces.map(\.name), ["a"], item.label)
      XCTAssertEqual(loaded.workspaces[0].boardWidgets, item.expected, item.label)
    }
  }
}
