import XCTest

@testable import Orbe

/// 定義の workspace の外の形。`list_automations` の定義は書いた位置に保存の形の ID で workspace を返し、そのまま書き戻すと
/// 何も変わらない。root を変えても定義も版も変わらない。workspace を消してもその席は消した workspace の ID のままで、そのままの
/// 書き戻しは場所付きで断る——自動化に別の workspace があるときのノードの席でも、黙って自動化の workspace を継がない。
///
/// 壊れると何が起きるか: AI が一覧の定義を戻すだけで版が進み、走っている回が止まる。root を変えただけで定義が変わったことに
/// なる。消えた workspace の席が落ち、書き戻した定義が別のリポジトリで走る。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
extension WindowControllerAutomationControlTests {
  private func workspaceId(_ wc: WindowController, _ name: String) throws -> String {
    try XCTUnwrap(
      wc.controlListWorkspaces().first { $0["name"] as? String == name }?["id"] as? String)
  }

  /// 自動化の workspace を継ぐ取得 `fetch` と、自分の workspace を書いた副作用 `say`。
  private func definition(automation: String, node: String) -> [String: Any] {
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

  private func created(_ wc: WindowController, _ definition: [String: Any]) throws -> Int {
    try XCTUnwrap(
      (success(wc.controlSetAutomation(automationId: nil, version: nil, definition))["automation"]
        as? [String: Any])?["automationId"] as? Int)
  }

  func testTheListedWorkspaceGoesBackUnchangedAndFollowsTheRoot() throws {
    let wc = try launch()
    _ = try success(wc.controlCreateWorkspace(name: "repo", rootPath: "/tmp/repo"))
    let main = try workspaceId(wc, "main")
    let repo = try workspaceId(wc, "repo")
    let id = try created(wc, definition(automation: main.lowercased(), node: repo))

    let listed = try listedDefinition(wc, id)
    XCTAssertEqual(listed["workspace"] as? String, main, "小文字で書いても保存の形で返る")
    XCTAssertNil(nodeSeat(listed, 0) as Any?, "継ぐノードの席は書かないまま")
    XCTAssertEqual(nodeSeat(listed, 1) as? String, repo)

    _ = try success(wc.controlSetAutomation(automationId: id, version: 1, listed))
    _ = try success(
      wc.controlSetWorkspaceRoot(
        workspaceId: try XCTUnwrap(UUID(uuidString: repo)), rootPath: "/tmp/moved"))

    XCTAssertEqual(wc.automationStore.automation(id)?.version, 1, "書き戻しも root の変更も版を進めない")
    XCTAssertEqual(
      NSDictionary(dictionary: try listedDefinition(wc, id)), NSDictionary(dictionary: listed))
  }

  /// 起動で読む workspace の ID は保存した ID そのもので、前の起動で書いた定義はそのまま書き戻せて何も変わらない（版も進まない）。
  /// 前の起動の保存（workspaces.json と自動化の DB）を直に置いて起動する。
  func testTheSavedIdsComeBackAndADefinitionWrittenBeforeTheLaunchGoesBackUnchanged() throws {
    let (main, repo) = (UUID(), UUID())
    let tab = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [tab], id: main),
        WorkspaceState(name: "repo", rootPath: "/tmp/repo", activeTab: 0, tabs: [], id: repo),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let id = try {
      try AutomationStore().create(
        try AutomationDefinition.decode(
          definition(automation: main.uuidString, node: repo.uuidString)), now: Date()
      ).id
    }()

    let wc = WindowController()

    XCTAssertEqual(try workspaceId(wc, "main"), main.uuidString)
    XCTAssertEqual(try workspaceId(wc, "repo"), repo.uuidString)
    let listed = try listedDefinition(wc, id)
    XCTAssertEqual(listed["workspace"] as? String, main.uuidString)
    XCTAssertEqual(nodeSeat(listed, 1) as? String, repo.uuidString)
    _ = try success(wc.controlSetAutomation(automationId: id, version: 1, listed))
    XCTAssertEqual(wc.automationStore.automation(id)?.version, 1, "書き戻しは版を進めない")
  }

  func testARemovedWorkspaceKeepsItsSeatAndItsWriteBackIsRefused() throws {
    let wc = try launch()
    _ = try success(wc.controlCreateWorkspace(name: "repo", rootPath: "/tmp/repo"))
    let main = try workspaceId(wc, "main")
    let repo = try workspaceId(wc, "repo")
    let id = try created(wc, definition(automation: main, node: repo))

    _ = try success(wc.controlRemoveWorkspace(workspaceId: try XCTUnwrap(UUID(uuidString: repo))))
    let listed = try listedDefinition(wc, id)

    XCTAssertEqual(listed["workspace"] as? String, main)
    XCTAssertEqual(nodeSeat(listed, 1) as? String, repo, "消えた席も落とさず、消した workspace の ID のまま出す")
    guard case .failure(let error) = wc.controlSetAutomation(automationId: id, version: 1, listed)
    else { return XCTFail("消えた workspace の書き戻しが通った") }
    XCTAssertEqual(error.code, -32602)
    XCTAssertEqual(
      error.message,
      "nodes[1].workspace: unknown workspace \(repo) (it may have been removed); pass a workspace id from "
        + "list_workspaces, or leave workspace out to run in the automation's workspace")

    var nulled = listed
    var nodes = try XCTUnwrap(nulled["nodes"] as? [[String: Any]])
    nodes[1]["workspace"] = NSNull()
    nulled["nodes"] = nodes
    guard
      case .failure(let nullError) = wc.controlSetAutomation(automationId: id, version: 1, nulled)
    else { return XCTFail("null の席が通った") }
    XCTAssertEqual(nullError.message, "invalid nodes[1].workspace", "null は「書かない」と同じにしない")
  }
}
