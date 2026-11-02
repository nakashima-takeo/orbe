import XCTest

@testable import Orbe

/// 定義の workspace の外の形。`list_automations` の定義は書いた位置に今の起動ごとの ID で workspace を返し、そのまま書き戻すと
/// 何も変わらない。root を変えても定義も版も変わらない。workspace を消すとその席は `null` になり、そのままの書き戻しは場所付きで
/// 断る——自動化に別の workspace があるときのノードの席でも、黙って自動化の workspace を継がない。
///
/// 壊れると何が起きるか: AI が一覧の定義を戻すだけで版が進み、走っている回が止まる。永続 ID が外に漏れる。root を変えただけで
/// 定義が変わったことになる。消えた workspace の席が落ち、書き戻した定義が別のリポジトリで走る。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
extension WindowControllerAutomationControlTests {
  private func workspaceId(_ wc: WindowController, _ name: String) throws -> Int {
    try XCTUnwrap(wc.controlListWorkspaces().first { $0["name"] as? String == name }?["id"] as? Int)
  }

  /// 自動化の workspace を継ぐ取得 `fetch` と、自分の workspace を書いた副作用 `say`。
  private func definition(automation: Int, node: Int) -> [String: Any] {
    [
      "name": "workspace", "workspace": automation,
      "nodes": [
        [
          "key": "fetch", "name": "取る", "trigger": ["kind": "manual"], "command": "pwd",
          "directory": ".", "coverage": "currentSet",
        ],
        [
          "key": "say", "name": "知らせる", "trigger": ["kind": "arrival"], "from": ["fetch"],
          "command": "say", "workspace": node, "directory": "bin", "deliver": "none",
        ],
      ],
    ]
  }

  private func listedDefinition(_ wc: WindowController, _ id: Int) throws -> [String: Any] {
    try XCTUnwrap(try listed(wc)[id]?["definition"] as? [String: Any])
  }

  private func nodeSeat(_ definition: [String: Any], _ index: Int) -> Any? {
    (definition["nodes"] as? [[String: Any]])?[index]["workspace"]
  }

  func testTheListedWorkspaceGoesBackUnchangedAndFollowsTheRoot() throws {
    let wc = try launch()
    _ = try success(wc.controlCreateWorkspace(name: "repo", rootPath: "/tmp/repo"))
    let main = try workspaceId(wc, "main")
    let repo = try workspaceId(wc, "repo")
    let id = try XCTUnwrap(
      (success(
        wc.controlSetAutomation(
          automationId: nil, version: nil, definition(automation: main, node: repo)))["automation"]
        as? [String: Any])?["automationId"] as? Int)

    let listed = try listedDefinition(wc, id)
    XCTAssertEqual(listed["workspace"] as? Int, main)
    XCTAssertNil(nodeSeat(listed, 0) as Any?, "継ぐノードの席は書かないまま")
    XCTAssertEqual(nodeSeat(listed, 1) as? Int, repo)

    _ = try success(wc.controlSetAutomation(automationId: id, version: 1, listed))
    _ = try success(wc.controlSetWorkspaceRoot(workspaceId: repo, rootPath: "/tmp/moved"))

    XCTAssertEqual(wc.automationStore.automation(id)?.version, 1, "書き戻しも root の変更も版を進めない")
    XCTAssertEqual(
      NSDictionary(dictionary: try listedDefinition(wc, id)), NSDictionary(dictionary: listed))
  }

  func testARemovedWorkspaceIsListedAsNullAndItsWriteBackIsRefused() throws {
    let wc = try launch()
    _ = try success(wc.controlCreateWorkspace(name: "repo", rootPath: "/tmp/repo"))
    let main = try workspaceId(wc, "main")
    let repo = try workspaceId(wc, "repo")
    let id = try XCTUnwrap(
      (success(
        wc.controlSetAutomation(
          automationId: nil, version: nil, definition(automation: main, node: repo)))["automation"]
        as? [String: Any])?["automationId"] as? Int)

    _ = try success(wc.controlRemoveWorkspace(workspaceId: repo))
    let listed = try listedDefinition(wc, id)

    XCTAssertEqual(listed["workspace"] as? Int, main)
    XCTAssertTrue(nodeSeat(listed, 1) is NSNull, "消えた席は落とさず null で出す")
    guard case .failure(let error) = wc.controlSetAutomation(automationId: id, version: 1, listed)
    else { return XCTFail("消えた workspace の書き戻しが通った") }
    XCTAssertEqual(error.code, -32602)
    XCTAssertEqual(
      error.message,
      "nodes[1].workspace: the workspace was removed; pass a workspace id from list_workspaces or "
        + "leave workspace out")
  }
}
