import Foundation
import XCTest

@testable import Orbe

/// 制御プロトコルの**method 名**と、その method が返すもの・ドメインへ届けるものを固定する。
///
/// 壊れると何が起きるか: `ControlServer` が result を包むキーを改名しても、method を別の
/// ドメイン動詞へ誤配線しても、宛先 ID を定数へ潰しても、`error` の有無しか見ていなければ
/// 1 本も落ちない。`orb list panes` は `result.panes` を `?? []` で読むので、サーバ側だけ
/// 改名すればエラーも出さず空表示になる——#50 が名指しした対照実験の応答側。
///
/// params の語（必須・型・optional）は `ControlWireTests+Params.swift` が持ち、ここは
/// その表（`validRequests` / `fixtures`）を借りて method と応答の側を見る。
extension ControlWireTests {

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
      "spawn_agent", "resume_agent", "prompt_agent",
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

    func wrapped(_ id: Int, _ method: String, _ key: String) -> Int? {
      let result = wire.request(id: id, method: method)?["result"] as? [String: Any]
      return (result?[key] as? [[String: Any]])?.count
    }

    XCTAssertEqual(
      wrapped(1, "list_workspaces", "workspaces"), 1, "list_workspaces は workspaces で包む")
    XCTAssertEqual(wrapped(2, "list_panes", "panes"), 2, "list_panes は panes で包む")
    XCTAssertEqual(wrapped(3, "list_agents", "agents"), 3, "list_agents は agents で包む")
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

  /// `activate_workspace` の成功形。ここが固定するのは wire の語（応答キー）で、返った `paneIds` が
  /// 実際に読めるペインを指すことは L4（`OrbeMcpProcessTests`）が実 `WindowController` で見る。
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
    _ = wire.request(
      id: 8, method: "prompt_agent", params: ["paneId": fake.paneId, "text": "p", "timeoutMs": 10])

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
    XCTAssertEqual(
      fake.prompts.map(\.paneId), [fake.paneId], "prompt_agent は解決したペインを controlPromptAgent へ渡す")
  }
}
