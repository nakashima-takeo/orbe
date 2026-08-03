import Foundation
import XCTest

@testable import Orbe

/// 制御プロトコルの**語**——method 名と params のキー——を固定する。
///
/// 壊れると何が起きるか: `ControlServer` の側だけ `params["state"]` を `params["agentState"]` へ
/// 改名しても、クライアント（`orb` / MCP ブリッジ / `orbe-report`）は古い名前を送り続け、値は
/// 黙って nil になる。エージェントの状態報告が全て無言で落ちるのに、テストは 1 本も落ちない
/// ——これが #50 に記録された対照実験そのもの。ここが語を押さえる唯一の場所になる。
///
/// 3 つの方式で押さえる。
/// 1. `-32602` / `-32004` ガードのある必須 param は、正しい名前一式で成功し 1 つ落とすと
///    そのコードになる（改名は「落とす」と等価なので成功側が落ちる）
/// 2. ガードの無い optional param は、Fake が受領値を記録して送った値と突き合わせる。
///    `messageSource` はここでしか固定できない（欠落しても目に見えず `-32602` にもならない）
/// 3. method 名は全数を回して `-32601` を返さないことを見る
///
/// **担保外**: `get_pane_text` の `scrollback` / `completion_accept` の `advance` /
/// `completion_update` の `buffer`・`cursor`。いずれも値が `SurfaceView` の libghostty 経路へ
/// 吸い込まれ、surface 無しでは真偽の差が観測できない。受け皿は `docs/testing/roadmap.md`
/// のスライス 2（L4）とスライス 5（L2）。
extension ControlWireTests {

  // MARK: - 表

  /// spec（`docs/spec/control-api.md` のツール節）に載る socket メソッドと、それぞれが受理する
  /// 正しい params 一式。観測できない担保外のキーは意図的に載せない。
  private func validRequests(_ fake: FakeControlTarget)
    -> [(method: String, params: [String: Any])]
  {
    let pane = fake.paneId
    return [
      ("list_workspaces", [:]),
      ("list_panes", [:]),
      ("list_agents", [:]),
      ("get_pane_text", ["paneId": pane]),
      ("send_text", ["paneId": pane, "text": "hello"]),
      ("send_key", ["paneId": pane, "key": "ctrl+c"]),
      ("spawn", ["workspaceId": 3, "cwd": "/tmp/cwd", "command": "zsh -l"]),
      ("activate_workspace", ["workspaceId": 3]),
      ("config_list", ["workspaceId": 3]),
      ("config_set", ["key": "font-size", "value": 14, "scope": "global", "workspaceId": 3]),
      ("create_workspace", ["name": "wsp", "rootPath": "/tmp/root"]),
      ("rename_workspace", ["workspaceId": 3, "name": "renamed"]),
      ("set_workspace_root", ["workspaceId": 3, "rootPath": "/tmp/root2"]),
      ("remove_workspace", ["workspaceId": 3]),
      ("split_pane", ["paneId": pane, "direction": "right", "command": "vim"]),
      ("close_pane", ["paneId": pane]),
      ("focus_pane", ["paneId": pane]),
      ("close_tab", ["tabId": 9]),
      (
        "report_agent",
        [
          "paneId": pane, "agent": "claude", "state": "waiting",
          "sessionId": "sess-9", "message": "続けますか", "messageSource": "tool",
        ]
      ),
      ("completion_accept", ["paneId": pane]),
    ]
  }

  /// 必須 param 1 件の契約。`method` から `key` を落とすと `code` になる。
  struct RequiredParam {
    let method: String
    let key: String
    let code: Int
  }

  /// 必須 param を 1 つ落としたときの帰結。宛先 ID が解決に失敗する経路は `-32004`、
  /// params の検証で弾く経路は `-32602`（この非対称は現状の契約そのもの）。
  private var requiredParams: [RequiredParam] {
    [
      RequiredParam(method: "get_pane_text", key: "paneId", code: -32004),
      RequiredParam(method: "send_text", key: "paneId", code: -32004),
      RequiredParam(method: "send_text", key: "text", code: -32602),
      RequiredParam(method: "send_key", key: "paneId", code: -32004),
      RequiredParam(method: "send_key", key: "key", code: -32602),
      RequiredParam(method: "activate_workspace", key: "workspaceId", code: -32602),
      RequiredParam(method: "report_agent", key: "paneId", code: -32004),
      RequiredParam(method: "report_agent", key: "agent", code: -32602),
      RequiredParam(method: "report_agent", key: "state", code: -32602),
      RequiredParam(method: "split_pane", key: "paneId", code: -32602),
      RequiredParam(method: "split_pane", key: "direction", code: -32602),
      RequiredParam(method: "close_pane", key: "paneId", code: -32602),
      RequiredParam(method: "focus_pane", key: "paneId", code: -32602),
      RequiredParam(method: "close_tab", key: "tabId", code: -32602),
      RequiredParam(method: "config_set", key: "key", code: -32602),
      RequiredParam(method: "config_set", key: "value", code: -32602),
      RequiredParam(method: "config_set", key: "scope", code: -32602),
      RequiredParam(method: "create_workspace", key: "name", code: -32602),
      RequiredParam(method: "rename_workspace", key: "workspaceId", code: -32602),
      RequiredParam(method: "rename_workspace", key: "name", code: -32602),
      RequiredParam(method: "set_workspace_root", key: "workspaceId", code: -32602),
      RequiredParam(method: "set_workspace_root", key: "rootPath", code: -32602),
      RequiredParam(method: "remove_workspace", key: "workspaceId", code: -32602),
      RequiredParam(method: "completion_accept", key: "paneId", code: -32004),
    ]
  }

  // MARK: - 方式 1: ガードのある必須 param

  /// 正しい名前の一式は成功し、必須キーを 1 つ落とすと定められたコードになる。
  /// サーバ側でキーを改名すると「落とした」のと同じになり、成功側の assert が落ちる。
  func testRequiredParamNamesAreFixed() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let fixtures = Dictionary(
      uniqueKeysWithValues: validRequests(fake).map { ($0.method, $0.params) })
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

  /// `split_pane` の `direction` が受理するのは `right` / `down` の 2 語だけ。
  func testSplitPaneDirectionVocabularyIsFixed() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    var id = 0

    for direction in ["right", "down"] {
      id += 1
      let response = wire.request(
        id: id, method: "split_pane", params: ["paneId": fake.paneId, "direction": direction])
      XCTAssertNil(response?["error"], "direction \(direction) は受理する")
      XCTAssertEqual(fake.splits.last?.direction, direction, "受理した direction がそのまま target へ届く")
    }

    for direction in ["left", "up", "vertical", "RIGHT", ""] {
      id += 1
      XCTAssertEqual(
        errorCode(
          wire.request(
            id: id, method: "split_pane", params: ["paneId": fake.paneId, "direction": direction])),
        -32602, "direction \(direction) は値域外で -32602")
    }
  }

  // MARK: - 方式 2: ガードの無い optional param

  /// `report_agent` の optional 3 件が名前どおり target へ届く。`message` は
  /// `AgentMessage(text:source:)` へ畳まれるので text と source の両方を見る。
  func testReportAgentOptionalParamsReachTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(
      id: 1, method: "report_agent",
      params: [
        "paneId": fake.paneId, "agent": "claude", "state": "waiting",
        "sessionId": "sess-9", "message": "続けますか", "messageSource": "tool",
      ])

    let reported = fake.reportedAgents.last
    XCTAssertEqual(reported?.paneId, fake.paneId, "paneId が指すペインへ適用する")
    XCTAssertEqual(reported?.agent, "claude", "agent が名前どおり届く")
    XCTAssertEqual(reported?.state, "waiting", "state が名前どおり届く")
    XCTAssertEqual(reported?.sessionId, "sess-9", "sessionId が名前どおり届く")
    XCTAssertEqual(reported?.messageText, "続けますか", "message は AgentMessage.text へ畳まれる")
    XCTAssertEqual(
      reported?.messageSource, "tool",
      "messageSource は AgentMessage.source へ畳まれる。-32602 ガードが無く欠落しても目に見えないため、"
        + "この経路以外にこの語を固定する手段が無い（#50 が名指しした穴）")
  }

  /// `message` を送らなければ `AgentMessage` 自体が組まれない（`messageSource` 単独では立たない）。
  func testReportAgentWithoutMessageCarriesNoAgentMessage() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(
      id: 1, method: "report_agent",
      params: [
        "paneId": fake.paneId, "agent": "claude", "state": "done", "messageSource": "tool",
      ])

    let reported = fake.reportedAgents.last
    XCTAssertNil(reported?.messageText, "message 無しなら AgentMessage を組まない")
    XCTAssertNil(reported?.messageSource, "message 無しなら source だけが独り立ちすることもない")
  }

  /// `spawn` の optional 3 件が名前どおり target へ届く（いずれもガードが無い）。
  func testSpawnOptionalParamsReachTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    let response = wire.request(
      id: 1, method: "spawn",
      params: ["workspaceId": 3, "cwd": "/tmp/cwd", "command": "zsh -l"])

    XCTAssertEqual(
      (response?["result"] as? [String: Any])?["paneId"] as? Int, fake.spawnedPaneId,
      "戻りは新ペイン ID を paneId で返す")
    let spawn = fake.spawns.last
    XCTAssertEqual(spawn?.workspaceId, 3, "workspaceId が名前どおり届く")
    XCTAssertEqual(spawn?.cwd, "/tmp/cwd", "cwd が名前どおり届く")
    XCTAssertEqual(spawn?.command, "zsh -l", "command が名前どおり届く")
  }

  /// `spawn` が失敗（target が nil を返す）したら -32000。
  func testSpawnFailureIsCannotExecute() {
    let fake = FakeControlTarget()
    fake.spawnedPaneId = nil
    let wire = startWire(target: fake)

    XCTAssertEqual(errorCode(wire.request(id: 1, method: "spawn")), -32000, "spawn 失敗は -32000")
  }

  /// 未知 workspace への `activate_workspace` は -32004（spawn と違いフォールバックしない）。
  func testActivateUnknownWorkspaceIsNotFound() {
    let fake = FakeControlTarget()
    fake.activateResult = nil
    let wire = startWire(target: fake)

    XCTAssertEqual(
      errorCode(wire.request(id: 1, method: "activate_workspace", params: ["workspaceId": 77])),
      -32004, "未知 workspace は -32004")
  }

  /// `split_pane` の optional `command` が名前どおり target へ届く。
  func testSplitPaneCommandReachesTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(
      id: 1, method: "split_pane",
      params: ["paneId": fake.paneId, "direction": "down", "command": "htop"])

    XCTAssertEqual(fake.splits.last?.command, "htop", "split_pane の command が名前どおり届く")
    XCTAssertEqual(fake.splits.last?.paneId, fake.paneId, "分割元 paneId が名前どおり届く")
  }

  /// `config_set` / `config_list` の optional `workspaceId` が名前どおり target へ届く。
  func testConfigWorkspaceIdReachesTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(
      id: 1, method: "config_set",
      params: ["key": "font-size", "value": 14, "scope": "workspace", "workspaceId": 5])
    _ = wire.request(id: 2, method: "config_list", params: ["workspaceId": 6])
    _ = wire.request(id: 3, method: "config_list")

    let set = fake.configSets.last
    XCTAssertEqual(set?.key, "font-size", "key が名前どおり届く")
    XCTAssertEqual(set?.value as? Int, 14, "value が名前どおり届く（型も保つ）")
    XCTAssertEqual(set?.scope, "workspace", "scope が名前どおり届く")
    XCTAssertEqual(set?.workspaceId, 5, "config_set の workspaceId が名前どおり届く")
    XCTAssertEqual(fake.configLists, [6, nil], "config_list の workspaceId は省略で nil（アクティブ WS）")
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
      "rootPath が名前どおり届き、省略は nil（アクティブペイン cwd 導出へ委ねる）")
  }

  // MARK: - 方式 3: method 名

  /// spec に載る socket メソッドは、いずれも `-32601` を返さない。
  /// method 名を改名すると未知メソッドに落ちてここが赤くなる。
  func testMethodNamesAreFixed() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    var id = 0

    for entry in validRequests(fake) {
      id += 1
      XCTAssertNotEqual(
        errorCode(wire.request(id: id, method: entry.method, params: entry.params)), -32601,
        "\(entry.method) は既知の method（改名すると -32601 に落ちる）")
    }

    // wait_for_event は待機を張るので即時応答しない。短い timeoutMs で必ず 1 行返させる。
    id += 1
    XCTAssertNotEqual(
      errorCode(wire.request(id: id, method: "wait_for_event", params: ["timeoutMs": 10])), -32601,
      "wait_for_event は handle が直接引き受ける（改名すると runWindowed の未知メソッドへ落ちる）")

    // 無応答契約の 2 つ。改名されると runCompletion の default に落ちて -32601 の行を書くので、
    // barrier の応答より先に届く＝ここで捕まる。
    wire.send([
      "jsonrpc": "2.0", "id": 900, "method": "completion_update",
      "params": ["paneId": fake.paneId, "buffer": "ls ", "cursor": 3],
    ])
    wire.send([
      "jsonrpc": "2.0", "id": 901, "method": "completion_end", "params": ["paneId": fake.paneId],
    ])
    wire.barrier()
  }
}
