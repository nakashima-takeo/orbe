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
/// 4 つの方式で押さえる。
/// 1. `-32602` / `-32004` ガードのある必須 param は、正しい名前一式で成功し 1 つ落とすと
///    そのコードになる（改名は「落とす」と等価なので成功側が落ちる）
/// 2. ガードの無い optional param は、Fake が受領値を記録して送った値と突き合わせる。
///    `messageSource` はここでしか固定できない（欠落しても目に見えず `-32602` にもならない）
/// 3. method 名は全数を回して `-32601` を返さないことを見る
/// 4. 成功したときの応答キーと、宛先 ID が届いたドメイン動詞を突き合わせる
///
/// **新しい method を足すとき**: `validRequests` に 1 行（必須）、必須 param があれば
/// `requiredParams` に 1 行、`Result` を返すなら `testDomainFailureReachesWireUnchanged` の
/// `resultReturning` に 1 行、宛先 ID を取るなら `testDestinationIdsReachTheirOwnDomainVerb` に
/// 1 行。`wait_for_event` と `completion_*` は `testMethodNamesAreFixed` が個別に扱う。
///
/// **担保外**: `get_pane_text` の `scrollback`（値が `SurfaceView` の libghostty 経路へ吸い込まれ、
/// surface 無しでは真偽の差が観測できない）と、`completion_accept` の `advance` /
/// `completion_update` の `buffer`・`cursor`（popup が生まれないと適用結果が出ず、無応答契約で
/// wire 側の観測面がゼロ）。受け皿は `docs/testing/roadmap.md` のスライス 2（L4）とスライス 5（L2）。
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

  /// `validRequests` を method 引きにしたもの。
  private func fixtures(_ fake: FakeControlTarget) -> [String: [String: Any]] {
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

  /// 型の違う値は「キーを落とした」のと同じ帰結になる。`as? Int` / `as? String` の
  /// キャストが唯一の型ガードなので、落とす側と同じ表で押さえられる。
  ///
  /// 型違いには**正しい値を隣の型へ移した値**を渡す（Int 期待なら数字文字列、String 期待なら
  /// 数値）。配列のような「どの型にもならない値」だけだと、キャストを片側へ緩める改変——例えば
  /// CLI が全部文字列で送ってくるのに合わせて `paneId` に `Int(文字列)` を許す——が 1 本も
  /// 落とさずに通る。spec の `-32602` は「欠落・型不一致・値域外」の 3 つを名指しており、
  /// ここが型不一致を受け持つ。
  func testWronglyTypedParamsAreRejectedLikeMissingOnes() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let fixtures = fixtures(fake)
    var id = 0

    for spec in requiredParams {
      // `config_set` の `value` だけは型を問わない（存在チェックのみ）。値の検証は設定
      // レジストリの domain が唯一の検証点という契約なので、ここで型を縛ると spec と食い違う。
      if spec.method == "config_set" && spec.key == "value" { continue }
      guard let full = fixtures[spec.method], let correct = full[spec.key] else { continue }

      id += 1
      var mistyped = full
      let moved: Any = correct is Int ? String(describing: correct) : 42
      mistyped[spec.key] = moved
      XCTAssertEqual(
        errorCode(wire.request(id: id, method: spec.method, params: mistyped)), spec.code,
        "\(spec.method) の \(spec.key) に型違い \(moved) を渡すと \(spec.code)（欠落と同じ帰結）")
    }
  }

  // MARK: - ドメインが返したエラーの素通し

  /// `Result` を返すメソッド群では、エラーコードを決めるのは `ControlServer` ではなく target。
  /// その `.failure` が書き換えも握り潰しもされず wire に出ることを固定する。
  ///
  /// これが spec の `-32004`（宛先 tab が見つからない）と `-32000`（最後の workspace 削除・
  /// 分割不可）を wire 上で成立させている唯一の経路。どの条件でドメインがそのコードを選ぶかは
  /// `WindowController` 側（L2）の担保で、ここが見るのは「選ばれたコードが素通しされるか」だけ。
  ///
  /// 壊れると、ドメインの拒否が `{"ok":true}` に化けて `orb` が成功と誤読する。
  func testDomainFailureReachesWireUnchanged() {
    let fake = FakeControlTarget()
    // 既存のどのコードとも重ならない番号にする——`ControlServer` が自前で生んだコードと
    // 取り違えたまま緑になるのを防ぐ（素通ししたことだけが通過の理由になる）。
    fake.domainFailure = ControlError(code: -31999, message: "domain refused")
    let wire = startWire(target: fake)
    var id = 0

    let resultReturning = [
      "split_pane", "close_pane", "focus_pane", "close_tab",
      "config_list", "config_set", "create_workspace", "rename_workspace",
      "set_workspace_root", "remove_workspace",
    ]
    let fixtures = fixtures(fake)

    for method in resultReturning {
      guard let params = fixtures[method] else {
        XCTFail("\(method) の正しい params 一式が表に無い")
        continue
      }
      id += 1
      let response = wire.request(id: id, method: method, params: params)

      XCTAssertEqual(
        errorCode(response), -31999,
        "\(method) は target が返した code をそのまま出す（自前のコードへ書き換えない）")
      XCTAssertEqual(
        (response?["error"] as? [String: Any])?["message"] as? String, "domain refused",
        "\(method) は message も素通しする（クライアントが理由を読む唯一の手掛かり）")
      XCTAssertNil(response?["result"], "\(method) の失敗に result を同居させない")
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

  /// `send_key` は文字列でも `ControlKey.parse` が解けない指定を値域外として弾く。
  /// 黙って無視して `{"ok":true}` を返すようになると、エージェントが送った enter が
  /// 実行されないまま成功と読まれる（`ControlKey.parse` 自体の語彙は L1 が持つ）。
  func testUnparsableKeySpecIsRejected() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    var id = 0

    // 未知のキー名 / 端末バイト表現を持たない cmd 付き単一文字 / 解けない綴り / 空。
    for spec in ["nosuchkey", "cmd+a", "ctrl+", ""] {
      id += 1
      XCTAssertEqual(
        errorCode(
          wire.request(id: id, method: "send_key", params: ["paneId": fake.paneId, "key": spec])),
        -32602, "解けないキー指定 \(spec) は -32602（無視して ok を返さない）")
    }
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

  // MARK: - 方式 4: 成功側（応答キーと宛先への配線）

  /// `list_*` は要素配列を自分の名前のキーで包む。3 つを違う長さにしてあるので、包みキーの
  /// 改名も別の list への誤配線もここで落ちる。押さえないと、サーバ側だけ `panes` を改名した
  /// とき `orb list panes` が `result.panes` を `?? []` で読んでエラーも出さず空表示になる
  /// ——#50 が名指しした失敗の応答側。
  func testListMethodsWrapResultsUnderTheirOwnKey() {
    let fake = FakeControlTarget()
    fake.workspaces = [["id": 1]]
    fake.panes = [["paneId": 1], ["paneId": 2]]
    fake.agents = [["command": "a"], ["command": "b"], ["command": "c"]]
    let wire = startWire(target: fake)

    let wrapped: [(method: String, key: String, count: Int)] = [
      ("list_workspaces", "workspaces", 1),
      ("list_panes", "panes", 2),
      ("list_agents", "agents", 3),
    ]
    var id = 0

    for entry in wrapped {
      id += 1
      let result = wire.request(id: id, method: entry.method)?["result"] as? [String: Any]
      XCTAssertEqual(
        (result?[entry.key] as? [[String: Any]])?.count, entry.count,
        "\(entry.method) は \(entry.key) で包み、自分のドメイン動詞の戻りを返す")
    }
  }

  /// ペイン宛メソッドの成功ペイロードのキー。`ok` / `text` / `buffer` はクライアントが
  /// 成否と結果を読む唯一の場所で、キーの改名も真偽の反転もここでしか捕まらない。
  func testPaneTargetedSuccessPayloadKeysAreFixed() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let pane = fake.paneId
    func result(_ id: Int, _ method: String, _ params: [String: Any]) -> [String: Any]? {
      wire.request(id: id, method: method, params: params)?["result"] as? [String: Any]
    }

    XCTAssertEqual(
      result(1, "get_pane_text", ["paneId": pane])?["text"] as? String, "",
      "get_pane_text は text で返す（surface 不在は空文字であってエラーではない）")
    XCTAssertEqual(
      result(2, "send_text", ["paneId": pane, "text": "hi"])?["ok"] as? Bool, true,
      "send_text の成功は ok: true")
    XCTAssertEqual(
      result(3, "send_key", ["paneId": pane, "key": "enter"])?["ok"] as? Bool, true,
      "send_key の成功は ok: true")
    XCTAssertTrue(
      result(4, "completion_accept", ["paneId": pane])?["buffer"] is NSNull,
      "popup が無ければ completion_accept は buffer: null（zsh はこの非 null で分岐する）")
  }

  /// `activate_workspace` の成功形。`paneIds` を読む現存の assert は `scripts/dev-verify.sh`
  /// だけで、スライス 2 でそれが廃止されると担保はここだけになる。
  func testActivateWorkspaceReturnsActiveIdAndPaneIds() {
    let fake = FakeControlTarget()
    fake.activateResult = (activeWorkspaceId: 3, paneIds: [11, 12])
    let wire = startWire(target: fake)

    let result =
      wire.request(id: 1, method: "activate_workspace", params: ["workspaceId": 3])?["result"]
      as? [String: Any]

    XCTAssertEqual(
      result?["activeWorkspaceId"] as? Int, 3, "前面化した workspace を activeWorkspaceId で返す")
    XCTAssertEqual(result?["paneIds"] as? [Int], [11, 12], "mount したペイン一式を paneIds で返す")
  }

  /// 宛先 ID がその method 専用のドメイン動詞へ、値ごと届く。ID を互いに違う値にしてあるので、
  /// `close_pane` と `focus_pane` を取り違える copy-paste 由来の誤配線も、受け取った ID を
  /// 定数へ潰す実装ミスも、どちらもここで落ちる。
  func testDestinationIdsReachTheirOwnDomainVerb() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(id: 1, method: "close_pane", params: ["paneId": 81])
    _ = wire.request(id: 2, method: "focus_pane", params: ["paneId": 82])
    _ = wire.request(id: 3, method: "close_tab", params: ["tabId": 83])
    _ = wire.request(id: 4, method: "rename_workspace", params: ["workspaceId": 84, "name": "r"])
    _ = wire.request(
      id: 5, method: "set_workspace_root", params: ["workspaceId": 85, "rootPath": "/tmp/r"])
    _ = wire.request(id: 6, method: "remove_workspace", params: ["workspaceId": 86])
    _ = wire.request(id: 7, method: "activate_workspace", params: ["workspaceId": 87])

    XCTAssertEqual(fake.closedPaneIds, [81], "close_pane は controlClosePane へ paneId を渡す")
    XCTAssertEqual(fake.focusedPaneIds, [82], "focus_pane は controlFocusPane へ paneId を渡す")
    XCTAssertEqual(fake.closedTabIds, [83], "close_tab は controlCloseTab へ tabId を渡す")
    XCTAssertEqual(
      fake.renamedWorkspaces.last?.workspaceId, 84, "rename_workspace は workspaceId を渡す")
    XCTAssertEqual(fake.renamedWorkspaces.last?.name, "r", "rename_workspace は name を渡す")
    XCTAssertEqual(
      fake.workspaceRoots.last?.workspaceId, 85, "set_workspace_root は workspaceId を渡す")
    XCTAssertEqual(
      fake.workspaceRoots.last?.rootPath, "/tmp/r", "set_workspace_root は rootPath を渡す")
    XCTAssertEqual(fake.removedWorkspaceIds, [86], "remove_workspace は workspaceId を渡す")
    XCTAssertEqual(fake.activatedWorkspaceIds, [87], "activate_workspace は workspaceId を渡す")
  }
}
