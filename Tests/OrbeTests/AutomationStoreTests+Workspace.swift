import XCTest

@testable import Orbe

/// 自動化の workspace の保存と書き換え。自動化の workspace は版を上げる欄で、替えると、それを継ぐコマンドのノードだけが何をするかが
/// 変わったノードになる。
///
/// 壊れると何が起きるか: 再起動で自動化の workspace が落ち、継ぐノードが読めない定義になる。自動化の workspace を替えても版が
/// 進まず、古い定義からの書き換えが通る。継ぐノードの走っている回が止まらず、古い場所の結果が新しい定義の結果として確定する。
/// 自分の workspace を書いたノードの回まで止まる。
extension AutomationStoreTests {
  private static let repo = UUID()
  private static let tools = UUID()

  /// 自動化の workspace を継ぐ取得 `fetch` と、自分の workspace を書いた副作用 `say`。
  private static func workspaceDefinition(_ workspace: UUID) -> AutomationDefinition {
    AutomationDefinition(
      name: "workspace", notify: nil, workspace: workspace,
      nodes: [
        DesignSceneFixtures.commandNode(
          "fetch", "取る", .manual, script: "pwd", directory: ".", coverage: .currentSet),
        DesignSceneFixtures.commandNode(
          "say", "知らせる", .arrival, from: ["fetch"], script: "say", workspace: tools,
          directory: "bin", deliver: .sideEffect),
      ])
  }

  func testTheAutomationWorkspaceSurvivesARestart() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.workspaceDefinition(Self.repo), now: Self.at).id)
    let written = try XCTUnwrap(store?.automation(id)?.definition)
    store = nil

    XCTAssertEqual(AutomationStore().automation(id)?.definition, written)
    XCTAssertEqual(written.workspace, Self.repo)
  }

  func testChangingTheAutomationWorkspaceReworksOnlyTheNodesThatInheritIt() throws {
    let store = AutomationStore()
    let id = try store.create(Self.workspaceDefinition(Self.repo), now: Self.at).id

    let same = try Self.rewrite(store, id, Self.workspaceDefinition(Self.repo))
    XCTAssertEqual(same.automation.version, 1, "何も変わらない書き戻しは版を進めない")
    XCTAssertEqual(same.reworked, [])

    let moved = try Self.rewrite(store, id, Self.workspaceDefinition(Self.tools))
    XCTAssertEqual(moved.automation.version, 2)
    XCTAssertEqual(moved.reworked, [store.nodeId(id, "fetch")], "自分の workspace を書いた say は変わらない")
  }
}
