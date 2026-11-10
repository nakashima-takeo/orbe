import Foundation
import XCTest

@testable import Orbe

/// 制御プロトコルの **params の語**——各 method が受理するキーとその型——を固定する。
///
/// 壊れると何が起きるか: `ControlServer` の側だけ `state` を `agentState` へ改名すると、古い名前を送り続ける
/// クライアント（`orb` / MCP ブリッジ / `orbe-report`）の要求は `unknown state` で断られる。`orbe-report` は応答を読まない
/// ので、エージェントの状態報告が全て無言で落ちる（#50 に記録された対照実験）。
///
/// 2 つの方式で押さえる。
/// 1. `-32602` / `-32004` ガードのある必須 param は、正しい名前一式で成功し 1 つ落とすと
///    そのコードになる（改名は「落とす」と等価なので成功側が落ちる）。型不一致は `ControlWireTests+Keys.swift` が全引数で見る
/// 2. ガードの無い optional param は、Fake が受領値を記録して送った値と突き合わせる。
///    `messageSource` はここでしか固定できない（欠落しても目に見えず `-32602` にもならない）
///
/// method 名と応答の側（result のキー・宛先への配線・ドメイン失敗の素通し）は
/// `ControlWireTests+Methods.swift` が持ち、そちらもここの `validRequests` / `fixtures` を使う。
///
/// **新しい method を足すとき**: `validRequests` に 1 行（必須）、必須 param があれば
/// `requiredParams` に 1 行、`Result` を返すなら `testDomainFailureReachesWireUnchanged` の
/// `resultReturning` に 1 行、宛先 ID を取るなら `testDestinationIdsReachTheirOwnDomainVerb` に
/// 1 行。`wait_for_event` と `completion_*` は `testMethodNamesAreFixed` が個別に扱う。
///
/// **担保外**: `get_tab_text` の `scrollback`（値が `SurfaceView` の libghostty 経路へ吸い込まれ、
/// surface 無しでは真偽の差が観測できない）と、`completion_accept` の `advance` /
/// `completion_update` の `buffer`・`cursor`（popup が生まれないと適用結果が出ず、無応答契約で
/// wire 側の観測面がゼロ）。受け皿は `docs/testing/roadmap.md` のスライス 2（L4）とスライス 5（L2）。
extension ControlWireTests {

  // MARK: - 表

  /// spec（`docs/spec/control/api.md` のツール節）に載る socket メソッドと、それぞれが受理する
  /// 正しい params 一式。観測できない担保外のキーは意図的に載せない。
  func validRequests(_ fake: FakeControlTarget)
    -> [(method: String, params: [String: Any])]
  {
    let tab = fake.tabId
    let ws = Self.workspace
    return [
      ("list_workspaces", [:]),
      ("list_tabs", ["workspaceId": ws]),
      ("list_agents", [:]),
      ("get_tab_text", ["tabId": tab]),
      ("send_text", ["tabId": tab, "text": "hello"]),
      ("send_key", ["tabId": tab, "key": "ctrl+c"]),
      ("spawn", ["workspaceId": ws, "cwd": "/tmp/cwd", "command": "zsh -l", "select": false]),
      ("spawn_agent", ["command": "codex", "workspaceId": ws, "cwd": "/tmp/cwd"]),
      (
        "resume_agent",
        ["command": "codex", "sessionId": "sess-1", "workspaceId": ws, "cwd": "/tmp/cwd"]
      ),
      ("activate_workspace", ["workspaceId": ws]),
      // 待機を張るので、表駆動で必ず 1 行返るよう短い timeoutMs を添える。
      ("prompt_agent", ["tabId": tab, "text": "hello", "timeoutMs": 10]),
      ("config_list", ["workspaceId": ws]),
      ("config_set", ["key": "font-size", "value": 14, "scope": "workspace", "workspaceId": ws]),
      ("create_workspace", ["name": "wsp", "rootPath": "/tmp/root"]),
      ("rename_workspace", ["workspaceId": ws, "name": "renamed"]),
      ("set_workspace_root", ["workspaceId": ws, "rootPath": "/tmp/root2"]),
      ("remove_workspace", ["workspaceId": ws]),
      ("focus_tab", ["tabId": 8]),
      ("close_tab", ["tabId": 9]),
      ("open_file", ["tabId": 8, "path": "/tmp/f.txt"]),
      (
        "report_agent",
        [
          "tabId": tab, "agent": "claude", "state": "waiting",
          "sessionId": "sess-9", "message": "続けますか", "messageSource": "tool",
          "reason": "other",
        ]
      ),
      ("completion_accept", ["tabId": tab]),
      ("session_log", ["since": "2026-01-01T00:00:00.000Z", "limit": 10]),
      ("restore_sessions", ["sessionIds": ["sess-1"]]),
      ("list_tasks", ["workspaceId": ws]),
      (
        "add_task",
        [
          "title": "経費精算", "status": "in_progress", "priority": "high", "due": "2026-10-06",
          "waitingReason": "返事", "description": "詳細", "workspaceId": ws,
          "links": [["kind": "pr", "repo": "o/n", "number": 214]],
        ]
      ),
      ("update_task", ["taskId": 7, "title": "改題"]),
      ("set_wait_condition", ["taskId": 7, "condition": NSNull()]),
      ("delete_task", ["taskId": 7]),
      ("start_task", ["taskId": 7, "branch": "feat/x", "prompt": "直して"]),
    ] + automationRequests + boardRequests
  }

  /// `validRequests` を method 引きにしたもの。
  func fixtures(_ fake: FakeControlTarget) -> [String: [String: Any]] {
    Dictionary(uniqueKeysWithValues: validRequests(fake).map { ($0.method, $0.params) })
  }

  /// 必須 param 1 件の契約。`method` から `key` を落とすと `code` になる。
  struct RequiredParam {
    let method: String
    let key: String
    let code: Int
  }

  /// 必須 param を 1 つ落としたときの帰結。宛先 ID が解決に失敗する経路は `-32004`、
  /// params の検証で弾く経路は `-32602`（この非対称は現状の契約そのもの）。
  var requiredParams: [RequiredParam] {
    [
      RequiredParam(method: "get_tab_text", key: "tabId", code: -32004),
      RequiredParam(method: "send_text", key: "tabId", code: -32004),
      RequiredParam(method: "send_text", key: "text", code: -32602),
      RequiredParam(method: "send_key", key: "tabId", code: -32004),
      RequiredParam(method: "send_key", key: "key", code: -32602),
      RequiredParam(method: "activate_workspace", key: "workspaceId", code: -32602),
      RequiredParam(method: "prompt_agent", key: "tabId", code: -32602),
      RequiredParam(method: "prompt_agent", key: "text", code: -32602),
      RequiredParam(method: "resume_agent", key: "command", code: -32602),
      RequiredParam(method: "resume_agent", key: "sessionId", code: -32602),
      RequiredParam(method: "report_agent", key: "tabId", code: -32004),
      RequiredParam(method: "report_agent", key: "agent", code: -32602),
      RequiredParam(method: "report_agent", key: "state", code: -32602),
      RequiredParam(method: "focus_tab", key: "tabId", code: -32602),
      RequiredParam(method: "close_tab", key: "tabId", code: -32602),
      RequiredParam(method: "open_file", key: "tabId", code: -32602),
      RequiredParam(method: "open_file", key: "path", code: -32602),
      RequiredParam(method: "config_set", key: "key", code: -32602),
      RequiredParam(method: "config_set", key: "value", code: -32602),
      RequiredParam(method: "config_set", key: "scope", code: -32602),
      RequiredParam(method: "create_workspace", key: "name", code: -32602),
      RequiredParam(method: "rename_workspace", key: "workspaceId", code: -32602),
      RequiredParam(method: "rename_workspace", key: "name", code: -32602),
      RequiredParam(method: "set_workspace_root", key: "workspaceId", code: -32602),
      RequiredParam(method: "set_workspace_root", key: "rootPath", code: -32602),
      RequiredParam(method: "remove_workspace", key: "workspaceId", code: -32602),
      RequiredParam(method: "completion_accept", key: "tabId", code: -32004),
      RequiredParam(method: "restore_sessions", key: "sessionIds", code: -32602),
      RequiredParam(method: "add_task", key: "title", code: -32602),
      RequiredParam(method: "update_task", key: "taskId", code: -32602),
      RequiredParam(method: "set_wait_condition", key: "taskId", code: -32602),
      RequiredParam(method: "set_wait_condition", key: "condition", code: -32602),
      RequiredParam(method: "delete_task", key: "taskId", code: -32602),
      RequiredParam(method: "start_task", key: "taskId", code: -32602),
      RequiredParam(method: "set_automation", key: "definition", code: -32602),
      RequiredParam(method: "run_automation", key: "automationId", code: -32602),
      RequiredParam(method: "pause_automation", key: "automationId", code: -32602),
      RequiredParam(method: "pause_automation", key: "paused", code: -32602),
      RequiredParam(method: "delete_automation", key: "automationId", code: -32602),
      RequiredParam(method: "get_automation_trial", key: "trialId", code: -32602),
      RequiredParam(method: "list_board_widgets", key: "workspaceId", code: -32602),
      RequiredParam(method: "add_board_widget", key: "workspaceId", code: -32602),
      RequiredParam(method: "add_board_widget", key: "kind", code: -32602),
      RequiredParam(method: "remove_board_widget", key: "workspaceId", code: -32602),
      RequiredParam(method: "remove_board_widget", key: "kind", code: -32602),
    ]
  }

  // MARK: - 方式 1: ガードのある必須 param

  /// 正しい名前の一式は成功し、必須キーを 1 つ落とすと定められたコードになる。
  /// サーバ側でキーを改名すると「落とした」のと同じになり、成功側の assert が落ちる。
  func testRequiredParamNamesAreFixed() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let fixtures = fixtures(fake)
    var id = 0

    for spec in requiredParams {
      guard let full = fixtures[spec.method] else {
        XCTFail("\(spec.method) の正しい params 一式が表に無い")
        continue
      }
      id += 1
      let accepted = wire.request(id: id, method: spec.method, params: full)
      XCTAssertNil(
        accepted?["error"],
        "\(spec.method) は正しいキー名（\(full.keys.sorted().joined(separator: ", "))）で成功する"
          + "——サーバ側だけキーを改名するとここが落ちる")

      id += 1
      var dropped = full
      dropped[spec.key] = nil
      XCTAssertEqual(
        errorCode(wire.request(id: id, method: spec.method, params: dropped)), spec.code,
        "\(spec.method) から \(spec.key) を落とすと \(spec.code)")
    }
  }

  /// `send_key` は文字列でも `ControlKey.parse` が解けない指定を値域外として弾く。
  /// 黙って無視して `{"ok":true}` を返すようになると、エージェントが送った enter が
  /// 実行されないまま成功と読まれる（`ControlKey.parse` 自体の語彙は L1 が持つ）。
  func testUnparsableKeySpecIsRejected() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    XCTAssertEqual(
      errorCode(
        wire.request(id: 1, method: "send_key", params: ["tabId": fake.tabId, "key": "nosuchkey"])),
      -32602, "解けないキー指定は -32602（無視して ok を返さない）")
  }

  /// `config_set` の `value: null` は「解除（継承へ戻す）」として受理する——欠落とは別物。
  /// `params["value"]` の存在チェックを「null も欠落扱い」へ締めると `orb config unset`
  /// （`NSNull()` を送る）が `-32602` になるが、値の意味論を見る L2 は通り続ける。
  func testConfigSetAcceptsNullValueAsUnset() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    let response = wire.request(
      id: 1, method: "config_set",
      params: ["key": "font-size", "value": NSNull(), "scope": "global"])

    XCTAssertNil(response?["error"], "value: null は解除として受理する（欠落扱いにしない）")
    XCTAssertTrue(fake.configSets.last?.value is NSNull, "null は NSNull のまま target へ届く")
  }

  // MARK: - 方式 2: ガードの無い optional param

  /// `report_agent` の optional 4 件が名前どおり target へ届く。`message` は
  /// `AgentMessage(text:source:)` へ畳まれるので text と source の両方を見る。
  func testReportAgentOptionalParamsReachTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(
      id: 1, method: "report_agent",
      params: [
        "tabId": fake.tabId, "agent": "claude", "state": "waiting",
        "sessionId": "sess-9", "message": "続けますか", "messageSource": "tool", "reason": "other",
      ])

    let reported = fake.reportedAgents.last
    XCTAssertEqual(reported?.tabId, fake.tabId, "tabId が指すタブへ適用する")
    XCTAssertEqual(reported?.agent, "claude", "agent が名前どおり届く")
    XCTAssertEqual(reported?.state, "waiting", "state が名前どおり届く")
    XCTAssertEqual(reported?.sessionId, "sess-9", "sessionId が名前どおり届く")
    XCTAssertEqual(reported?.messageText, "続けますか", "message は AgentMessage.text へ畳まれる")
    XCTAssertEqual(
      reported?.messageSource, "tool",
      "messageSource は AgentMessage.source へ畳まれる。-32602 ガードが無く欠落しても目に見えないため、"
        + "この経路以外にこの語を固定する手段が無い（#50 が名指しした穴）")
    XCTAssertEqual(reported?.reason, "other", "reason が名前どおり届く（セッションログの closed に載る語）")
    XCTAssertEqual(
      reported?.reporterGroup, ProcessGroup.terminalGroup(of: getpid()),
      "報告者は params でなく接続の向こうのプロセス（ここではテスト自身）から辿る")
  }

  /// `spawn` の optional 4 件が名前どおり target へ届く（`select` 以外はガードが無い）。
  func testSpawnOptionalParamsReachTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let workspace = UUID()

    let response = wire.request(
      id: 1, method: "spawn",
      params: [
        "workspaceId": workspace.uuidString, "cwd": "/tmp/cwd", "command": "zsh -l",
        "select": false,
      ])

    XCTAssertEqual(
      (response?["result"] as? [String: Any])?["tabId"] as? Int, fake.spawnedTabId,
      "戻りは新タブ ID を tabId で返す")
    let spawn = fake.spawns.last
    XCTAssertEqual(spawn?.workspaceId, workspace, "workspaceId が名前どおり届く")
    XCTAssertEqual(spawn?.cwd, "/tmp/cwd", "cwd が名前どおり届く")
    XCTAssertEqual(spawn?.command, "zsh -l", "command が名前どおり届く")
    XCTAssertEqual(spawn?.selects, false, "select が名前どおり届く")
  }

  /// `spawn` の `select` は省略で選び、真偽値以外は -32602 で何も開かない——数の 0 を偽と読むと、
  /// 呼び出し側の型の取り違えが「人が見ているタブを奪う／奪わない」の差へ黙って化ける。
  func testSpawnSelectDefaultsToTrueAndRejectsNonBool() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    XCTAssertNil(errorCode(wire.request(id: 1, method: "spawn")), "select 省略で成功する")
    XCTAssertEqual(fake.spawns.last?.selects, true, "select 省略は選ぶ")
    XCTAssertEqual(
      errorCode(wire.request(id: 2, method: "spawn", params: ["select": 0])), -32602,
      "数は真偽値として受けない")
    XCTAssertEqual(fake.spawns.count, 1, "弾いた spawn は target へ届かない")
  }

  /// 未知 workspace への `activate_workspace` は -32004。
  func testActivateUnknownWorkspaceIsNotFound() {
    let fake = FakeControlTarget()
    fake.activateResult = nil
    let wire = startWire(target: fake)

    XCTAssertEqual(
      errorCode(
        wire.request(
          id: 1, method: "activate_workspace", params: ["workspaceId": UUID().uuidString])),
      -32004, "未知 workspace は -32004")
  }

  /// `config_set` / `config_list` の optional `workspaceId` が名前どおり target へ届く。
  func testConfigWorkspaceIdReachesTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let (setIn, listedIn) = (UUID(), UUID())

    _ = wire.request(
      id: 1, method: "config_set",
      params: [
        "key": "font-size", "value": 14, "scope": "workspace", "workspaceId": setIn.uuidString,
      ])
    _ = wire.request(id: 2, method: "config_list", params: ["workspaceId": listedIn.uuidString])
    _ = wire.request(id: 3, method: "config_list")

    let set = fake.configSets.last
    XCTAssertEqual(set?.key, "font-size", "key が名前どおり届く")
    XCTAssertEqual(set?.value as? Int, 14, "value が名前どおり届く（型も保つ）")
    XCTAssertEqual(set?.scope, "workspace", "scope が名前どおり届く")
    XCTAssertEqual(set?.workspaceId, setIn, "config_set の workspaceId が名前どおり届く")
    XCTAssertEqual(
      fake.configLists, [listedIn, nil], "config_list の workspaceId は省略で nil（アクティブ WS）")
  }

  /// `create_workspace` の optional `rootPath` が名前どおり target へ届く。
  func testCreateWorkspaceRootPathReachesTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(
      id: 1, method: "create_workspace", params: ["name": "a", "rootPath": "/tmp/r"])
    _ = wire.request(id: 2, method: "create_workspace", params: ["name": "b"])

    XCTAssertEqual(fake.createdWorkspaces.map(\.name), ["a", "b"], "name が名前どおり届く")
    XCTAssertEqual(
      fake.createdWorkspaces.map(\.rootPath), ["/tmp/r", nil],
      "rootPath が名前どおり届き、省略は nil（アクティブタブ cwd 導出へ委ねる）")
  }
}
