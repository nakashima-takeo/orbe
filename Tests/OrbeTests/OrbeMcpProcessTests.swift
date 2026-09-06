import XCTest

@testable import Orbe

/// 実 `orbe-mcp` を子プロセスで起こし、MCP の `tools/call` → control.sock → 実 `WindowController`
/// までの導通と、L3 が固定できなかった `get_tab_text` の `scrollback` を測る。
///
/// 壊れると何が起きるか: MCP ブリッジがツール名を control のメソッドへ載せ替えられなくなっても、
/// `isError` の畳み込みが消えても、実タブへの注入・読み取りが no-op に倒れても、どのテストも
/// 落ちなくなる。AI から Orbe を駆動する MCP の口が黙って死に、気づくのは人が手で触ったときになる。
///
/// 重要: 実 `NSWindow` に `SurfaceView` を接続し、実タブでシェルを走らせる（GhosttyKit 必須）。
/// ヘッドレスな純ロジック検証ではない。
final class OrbeMcpProcessTests: OrbeTestCase {
  /// 前面 workspace のタブ id。`active` は workspace ごとに 1 枚立つので `list_tabs` の応答から
  /// 前面を選り分けられない——期待は in-process から取り、MCP 越しの `list_tabs` がそのタブを
  /// `active` で返すことの導通だけをここで確かめる。
  private func liveTabId(_ control: ControlProcess) throws -> Int {
    let expected = try XCTUnwrap(control.target.current.tabs.first, "タブが 1 つも無い").id
    let tabs = try XCTUnwrap(
      control.mcpJSON("list_tabs")["tabs"] as? [[String: Any]], "list_tabs が tabs を返さない")
    let live = tabs.first { $0["tabId"] as? Int == expected }
    XCTAssertEqual(live?["active"] as? Bool, true, "MCP 越しの list_tabs が前面タブを active で返す")
    return expected
  }

  /// タブへ 1 行流して実行させる（`send_text` はペースト相当で自己実行しないため enter を別送する）。
  private func runInTab(_ control: ControlProcess, tab: Int, command: String) {
    XCTAssertFalse(
      control.mcpCall("send_text", ["tabId": tab, "text": command]).isError, "send_text が失敗した")
    XCTAssertFalse(
      control.mcpCall("send_key", ["tabId": tab, "key": "enter"]).isError, "send_key が失敗した")
  }

  private func tabText(_ control: ControlProcess, tab: Int, scrollback: Bool = false) -> String {
    control.mcpJSON("get_tab_text", ["tabId": tab, "scrollback": scrollback])["text"] as? String
      ?? ""
  }

  /// 「シェルが実際に実行した」ことの証拠になるコマンドと目印。目印はコマンド行の中では 2 つの
  /// 文字列リテラルに割れているため、**連結された形はシェルが引用符除去を評価した出力にしか
  /// 現れない**。入力行がそのまま描き返されても目印にはならないので、判定はプロンプトのテーマや
  /// rc の描画挙動に依らない。
  private func executionProbe() -> (command: String, marker: String) {
    let id = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    return ("echo L4D\"\"ONE_\(id)", "L4DONE_\(id)")
  }

  /// 実行済みになるまで待つ。可視範囲は長い出力で流れるため scrollback 側で見る。
  private func waitForExecution(_ control: ControlProcess, tab: Int, marker: String) -> Bool {
    waitUntil(ControlProcess.tabSettleTimeout) {
      tabText(control, tab: tab, scrollback: true).contains(marker)
    }
  }

  /// `tools/list` の語彙。`prompt_agent` が出ており、`wait_for_event` の schema に `after` / `value`、
  /// `spawn_agent` / `resume_agent` に `timeoutMs` がある。description は「問うなら prompt_agent、
  /// 生の入力は send_text＋send_key」の導線と `ready:false` の意味を持つ——AI が読む唯一の説明なので、
  /// ここが欠けると AI は `send_text` → `wait_for_event` の取りこぼす手順を組み続ける。
  func testToolsListExposesPromptAgentAndTheHistoryCursor() throws {
    let tools = ControlProcess.mcpToolsList()
    func tool(_ name: String) throws -> [String: Any] {
      try XCTUnwrap(tools.first { $0["name"] as? String == name }, "\(name) が tools/list に無い")
    }
    func properties(_ tool: [String: Any]) -> [String: Any] {
      (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    }

    let prompt = try tool("prompt_agent")
    XCTAssertEqual(
      Set((prompt["inputSchema"] as? [String: Any])?["required"] as? [String] ?? []),
      ["tabId", "text"], "prompt_agent の必須は tabId と text")
    XCTAssertNotNil(properties(prompt)["timeoutMs"], "prompt_agent は timeoutMs を受ける")
    let promptDescription = prompt["description"] as? String ?? ""
    XCTAssertTrue(
      promptDescription.contains("send_text") && promptDescription.contains("wait_for_event"),
      "prompt_agent の description が send_text / wait_for_event との使い分けを導く: \(promptDescription)")

    let wait = properties(try tool("wait_for_event"))
    XCTAssertNotNil(wait["after"], "wait_for_event は after を受ける")
    XCTAssertNotNil(wait["value"], "wait_for_event は value を受ける")

    // description が写す既定タイムアウトは control の `WaitTimeout` と同じ値——AI が timeoutMs を
    // 決める唯一の情報源なので、写しが古いと省略時の待ち時間を誤って見積もる（`KINDS:` と同じ守り方）。
    func description(_ property: Any?) -> String {
      (property as? [String: Any])?["description"] as? String ?? ""
    }
    XCTAssertTrue(
      description(wait["timeoutMs"]).contains("既定 \(WaitTimeout.eventDefaultMs)"),
      "wait_for_event の timeoutMs が WaitTimeout.eventDefaultMs と食い違っている")
    XCTAssertTrue(
      promptDescription.contains("既定 \(WaitTimeout.promptDefaultMs) ms")
        && description(properties(prompt)["timeoutMs"])
          .contains("既定 \(WaitTimeout.promptDefaultMs)・上限 \(WaitTimeout.maxMs)"),
      "prompt_agent の既定 / 上限が WaitTimeout と食い違っている: \(promptDescription)")

    for name in ["spawn_agent", "resume_agent"] {
      let launch = try tool(name)
      XCTAssertNotNil(properties(launch)["timeoutMs"], "\(name) は timeoutMs を受ける")
      XCTAssertTrue(
        description(properties(launch)["timeoutMs"]).contains("既定 \(WaitTimeout.launchDefaultMs)"),
        "\(name) の timeoutMs が WaitTimeout.launchDefaultMs と食い違っている")
    }
    XCTAssertTrue(
      (try tool("spawn_agent")["description"] as? String ?? "").contains("ready:false"),
      "spawn_agent の description が ready:false の意味を書く")
  }

  /// `session_log` / `restore_sessions` が tools/list に在り、AI が「閉じたまま戻っていないもの」を導く
  /// 手順（closed の最後のイベント × list_tabs に居ない → restore_sessions）が description に書いてある。
  /// この導線が無いと AI は生ログを前に何を戻せばよいか決められず、生きているセッションを二重に戻す。
  func testToolsListExposesSessionLogAndRestoreWithTheDerivationRecipe() throws {
    let tools = ControlProcess.mcpToolsList()
    func tool(_ name: String) throws -> [String: Any] {
      try XCTUnwrap(tools.first { $0["name"] as? String == name }, "\(name) が tools/list に無い")
    }
    let log = try tool("session_log")
    let logDescription = log["description"] as? String ?? ""
    for word in ["closed", "list_tabs", "restore_sessions"] {
      XCTAssertTrue(logDescription.contains(word), "session_log の description に \(word) が無い")
    }
    XCTAssertEqual(
      Set(
        ((log["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?.keys ?? [:].keys),
      ["since", "until", "limit", "sessionId"])
    XCTAssertTrue(
      logDescription.contains("既定 \(ControlServer.sessionLogDefaultLimit)"), "limit の既定を写す")

    let restore = try tool("restore_sessions")
    XCTAssertEqual(
      (restore["inputSchema"] as? [String: Any])?["required"] as? [String], ["sessionIds"])
    let restoreDescription = restore["description"] as? String ?? ""
    XCTAssertTrue(restoreDescription.contains("resume_agent"), "resume_agent との違い（起動しない）を書く")
    XCTAssertTrue(restoreDescription.contains("already-present"), "id ごとの status の語を書く")
  }

  /// `session_log` / `restore_sessions` の `tools/call` が control へ届く。ブリッジはツール名を method 名として
  /// 総称転送するので、この 2 語が control 側の綴りと食い違えば tools/list は緑のまま呼び出しだけが死ぬ。
  func testSessionLogAndRestoreSessionsReachControlThroughTheBridge() throws {
    let control = try startControlProcess()

    let log = control.mcpJSON("session_log", ["limit": 5])
    XCTAssertNotNil(log["events"] as? [[String: Any]], "session_log が events を返す: \(log)")
    XCTAssertEqual(log["truncated"] as? Bool, false)

    let restore = control.mcpJSON("restore_sessions", ["sessionIds": ["nope-1"]])
    XCTAssertEqual(
      (restore["results"] as? [[String: Any]])?.first?["status"] as? String, "unknown",
      "配列の sessionIds がそのまま届き、id ごとの status が返る: \(restore)")
  }

  /// `send_text` ＋ `send_key enter` でタブのシェルが実際にコマンドを**実行**する
  /// （`send_text` はペースト相当なので、enter を別送しなければプロンプトに留まったままになる）。
  func testSendTextAndEnterExecutesInTab() throws {
    let control = try startControlProcess()
    let tab = try liveTabId(control)
    let probe = executionProbe()

    runInTab(control, tab: tab, command: probe.command)

    XCTAssertTrue(
      waitForExecution(control, tab: tab, marker: probe.marker),
      "enter を送ってもコマンドが実行されていない: \(tabText(control, tab: tab, scrollback: true))")
  }

  /// `list_workspaces` の全行に `dormantAgentCount` が出る（休眠可視化の源）。
  func testListWorkspacesExposesDormantAgentCount() throws {
    let control = try startControlProcess()
    let rows = try XCTUnwrap(control.mcpJSON("list_workspaces")["workspaces"] as? [[String: Any]])
    XCTAssertFalse(rows.isEmpty, "workspace が 1 つも返らない")
    for row in rows {
      XCTAssertNotNil(
        row["dormantAgentCount"] as? Int, "MCP 越しでも各行に dormantAgentCount(Int) が出る")
    }
  }

  /// 背景 workspace を `activate_workspace` すると、返る `tabIds` の先頭が実際に読めるタブになる
  /// （mount まで届いている）。fixture が背景 WS を必ず作るので、この検証は環境次第で省略されない。
  func testActivateBackgroundWorkspaceYieldsReadableTab() throws {
    let control = try startControlProcess()
    let workspaces = try XCTUnwrap(
      control.mcpJSON("list_workspaces")["workspaces"] as? [[String: Any]])
    let background = try XCTUnwrap(
      workspaces.first { $0["active"] as? Bool == false }, "背景 workspace が fixture に無い")
    let backgroundId = try XCTUnwrap(background["id"] as? Int)

    let activated = control.mcpJSON("activate_workspace", ["workspaceId": backgroundId])
    let tabIds = try XCTUnwrap(activated["tabIds"] as? [Int], "activate が tabIds を返さない")
    let tab = try XCTUnwrap(tabIds.first, "activate 後も tabIds が空（タブが mount されていない）")

    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) {
        !tabText(control, tab: tab).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      },
      "activate したタブ \(tab) の画面が空のまま（surface が生成されていない）")
  }

  /// 未知の `workspaceId` は control のエラーが MCP の `isError` へ畳まれ、本文に理由が残る。
  func testActivateUnknownWorkspaceIsReportedAsError() throws {
    let control = try startControlProcess()
    let call = control.mcpCall("activate_workspace", ["workspaceId": 999_999])
    XCTAssertTrue(call.isError, "未知 workspaceId は isError:true になる")
    XCTAssertTrue(
      call.text.contains("workspace not found"), "error 本文に理由が残る: \(call.text)")
  }

  /// `get_tab_text` の `scrollback` が効く。可視範囲を溢れる出力を流すと、`true` の結果は
  /// `false` の結果を真に含む（`false` で消えた古い行が `true` にだけ残る）。
  /// Fake target では `controlReadText` が surface 不在で nil を返すため、実 surface でしか測れない。
  func testGetTabTextScrollbackIncludesHistoryBeyondViewport() throws {
    let control = try startControlProcess()
    let tab = try liveTabId(control)

    let probe = executionProbe()
    runInTab(control, tab: tab, command: "seq 1 200; \(probe.command)")
    XCTAssertTrue(
      waitForExecution(control, tab: tab, marker: probe.marker), "seq の出力が出切らない")

    let visible = tabText(control, tab: tab)
    let full = tabText(control, tab: tab, scrollback: true)
    XCTAssertFalse(
      visible.contains("\n1\n"), "可視範囲には最初の行が残らない（画面より長い出力を流した前提）")
    XCTAssertTrue(full.contains("\n1\n"), "scrollback:true は画面外へ流れた行を含む")
    XCTAssertGreaterThan(
      full.count, visible.count, "scrollback:true の方が長い（両者が同じなら真偽が効いていない）")
  }
}
