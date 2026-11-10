import OrbeSessionLog
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

  /// Home の rules・⌘⇧X の役目の指示（日英）・同梱プラグインの自動化のスキルが名指しする MCP のツールは、どれも
  /// `tools/list` にある。どれも claude が読む手引きで、orbe-mcp は別ターゲットなので、ツールを改名・削除しても
  /// コンパイルもほかのテストも通ってしまう。
  func testAgentInstructionsNameOnlyToolsTheBridgeLists() throws {
    let names = Set(ControlProcess.mcpToolsList().compactMap { $0["name"] as? String })
    let pattern = try NSRegularExpression(pattern: "`([a-z]+(?:_[a-z]+)+|spawn)`")
    let skill = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("app/agent-plugin/plugins/orbe-agent/skills/automation/SKILL.md")
    var texts = [("自動化のスキル", try String(contentsOf: skill, encoding: .utf8))]
    for language in Language.allCases {
      texts += [
        ("\(language) の Home の rules", HomeTemplate.rules(language, home: "/home")),
        (
          "\(language) の ⌘⇧X の役目の指示",
          SecretaryText.instructions(for: .palette, language, pluginName: nil)
        ),
      ]
    }
    for (label, text) in texts {
      let named = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range(at: 1), in: text)!])
      }
      XCTAssertFalse(named.isEmpty, "\(label): 前提: ツールを名指ししている")
      for name in named {
        XCTAssertTrue(names.contains(name), "\(label)が tools/list に無い \(name) を名指ししている")
      }
    }
  }

  /// 裏の agent の回の道具（札があるときだけ出す）の名前と `inputSchema` の欄、説明が写すページの既定・上限・大きさ・行と報告の
  /// 上限は、Orbe 本体の正本（`AutomationRunSession.Tool` とその受ける引数・ページの定数・`AutomationOutputs.rowKiB`）と同じで、
  /// `read_run_rows` は claude が結果をファイルに書き出す閾値を上げる。orbe-mcp は別ターゲットなので、片側だけ直してもコンパイルも
  /// ほかのテストも通り、その道具を持つ役割の回が毎回「ツールが使えなかった」か外れた件で失敗する。
  func testRunToolsMatchTheRunSession() throws {
    let all = AutomationRunSession.Tool.allCases.map(\.rawValue)
    let tools = ControlProcess.mcpToolsList(
      env: ["ORBE_RUN_TOKEN": "t", "ORBE_RUN_TOOLS": all.joined(separator: ",")])
    func tool(_ name: String) throws -> [String: Any] {
      try XCTUnwrap(tools.first { $0["name"] as? String == name }, "\(name) が tools/list に無い")
    }

    XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), Set(all))
    for runTool in AutomationRunSession.Tool.allCases {
      let schema = try tool(runTool.rawValue)["inputSchema"] as? [String: Any]
      let properties = schema?["properties"] as? [String: Any] ?? [:]
      XCTAssertEqual(
        Set(properties.keys), runTool.arguments,
        "\(runTool.rawValue) の inputSchema の欄と、その道具が受ける引数（片側だけ足すとその鍵付きの呼び出しが毎回外れる）")
    }
    let read = try tool("read_run_rows")
    let properties = (read["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
    let limit = (properties?["limit"] as? [String: Any])?["description"] as? String ?? ""
    for copied in [
      "1 to \(AutomationRunSession.pageLimit);", "default \(AutomationRunSession.pageDefault);",
      "about \(AutomationRunSession.pageBytes >> 10) KiB)",
    ] {
      XCTAssertTrue(limit.contains(copied), "\(copied): \(limit)")
    }
    XCTAssertEqual(
      (read["_meta"] as? [String: Any])?["anthropic/maxResultSizeChars"] as? Int, 500_000)
    for name in ["put_items", "put_rows", "put_report"] {
      let description = try tool(name)["description"] as? String ?? ""
      XCTAssertTrue(
        description.contains("at most \(AutomationOutputs.rowKiB) KiB"), "\(name): \(description)")
    }
  }

  /// `tools/list` の description が写す既定・上限は control の正本（`WaitTimeout` / `SessionLogLimits`）と
  /// 同じ値。AI が timeoutMs・limit・一度に戻す件数を決める唯一の情報源なので、写しが古いと省略時の
  /// 待ち時間を誤って見積もり、上限を超えた要求を組む。数字の直後の区切りまで含めて比べる——部分一致だと
  /// 10000 → 1000 のような下げ方向のドリフトを取り逃す。
  func testToolsListDescriptionsMatchTheControlLimits() throws {
    let tools = ControlProcess.mcpToolsList()
    func tool(_ name: String) throws -> [String: Any] {
      try XCTUnwrap(tools.first { $0["name"] as? String == name }, "\(name) が tools/list に無い")
    }
    func description(_ tool: [String: Any], property: String? = nil) -> String {
      guard let property else { return tool["description"] as? String ?? "" }
      let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
      return (properties?[property] as? [String: Any])?["description"] as? String ?? ""
    }

    XCTAssertTrue(
      description(try tool("wait_for_event"), property: "timeoutMs")
        .contains("既定 \(WaitTimeout.eventDefaultMs)"),
      "wait_for_event の timeoutMs が WaitTimeout.eventDefaultMs と食い違っている")
    let prompt = try tool("prompt_agent")
    XCTAssertTrue(
      description(prompt).contains("既定 \(WaitTimeout.promptDefaultMs) ms")
        && description(prompt, property: "timeoutMs")
          .contains("既定 \(WaitTimeout.promptDefaultMs)・上限 \(WaitTimeout.maxMs)"),
      "prompt_agent の既定 / 上限が WaitTimeout と食い違っている: \(description(prompt))")
    XCTAssertTrue(
      description(try tool("get_automation_trial")).contains(
        "`timeoutMs` (default \(WaitTimeout.promptDefaultMs), max \(WaitTimeout.maxMs))"),
      "get_automation_trial の既定 / 上限が WaitTimeout と食い違っている")
    for name in ["spawn_agent", "resume_agent"] {
      XCTAssertTrue(
        description(try tool(name), property: "timeoutMs")
          .contains("既定 \(WaitTimeout.launchDefaultMs)"),
        "\(name) の timeoutMs が WaitTimeout.launchDefaultMs と食い違っている")
    }

    let log = description(try tool("session_log"))
    XCTAssertTrue(log.contains("既定 \(SessionLogLimits.defaultLimit)（"), "limit の既定を写す")
    XCTAssertTrue(log.contains("上限 \(SessionLogLimits.maxLimit)。"), "limit の上限を写す")
    XCTAssertTrue(
      description(try tool("restore_sessions"), property: "sessionIds")
        .contains("\(SessionLogLimits.restoreMaxIds) 件"),
      "sessionIds の上限を写す")
  }

  /// `tools/list` に出る全ツールが control の method として通る。ブリッジはツール名をそのまま method 名へ
  /// 載せ替えるので、片側だけ綴りが変わると tools/list は緑のまま呼び出しだけが `method not found` で死ぬ。
  /// 引数は実在しない宛先・最短の待ちに向ける（届いたかだけを見るので、成否は問わない）。
  ///
  /// control の拒否は MCP の `isError` へ畳まれ、本文に理由が残る——畳まれなければ AI は失敗を成功と読む。
  func testEveryListedToolReachesControlAndRejectionsBecomeIsError() throws {
    let control = try startControlProcess()
    let tools = ControlProcess.mcpToolsList()
    XCTAssertFalse(tools.isEmpty, "tools/list が空")
    let nowhere: [String: Any] = [
      "tabId": 999_999, "workspaceId": UUID().uuidString, "taskId": 999_999, "timeoutMs": 1,
    ]
    for tool in tools {
      let name = try XCTUnwrap(tool["name"] as? String)
      let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
      let call = control.mcpCall(
        name, nowhere.filter { properties?[$0.key] != nil })
      XCTAssertFalse(
        call.text.hasPrefix("method not found"), "\(name) が control の method として通らない: \(call.text)")
    }

    let rejected = control.mcpCall("activate_workspace", ["workspaceId": UUID().uuidString])
    XCTAssertTrue(rejected.isError, "control の拒否は isError:true になる")
    XCTAssertTrue(
      rejected.text.contains("workspace not found"), "error 本文に理由が残る: \(rejected.text)")
  }

  /// workspaceId を取るツールは、どれも workspace の ID を文字列で受けると説明する（タスクの付き先だけは null で「なし」も）。
  /// 整数と説明すると、AI が送る値はどれも control に断られる。
  func testEveryWorkspaceIdIsDescribedAsAString() throws {
    let clearable: Set<String> = ["add_task", "update_task"]
    var described: [String] = []
    for tool in ControlProcess.mcpToolsList() {
      let name = try XCTUnwrap(tool["name"] as? String)
      let properties =
        (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: [String: Any]]
      guard let property = properties?["workspaceId"] else { continue }
      described.append(name)
      if clearable.contains(name) {
        XCTAssertEqual(property["type"] as? [String], ["string", "null"], name)
      } else {
        XCTAssertEqual(property["type"] as? String, "string", name)
      }
    }
    XCTAssertFalse(described.isEmpty, "workspaceId を取るツールが無い")
  }

  /// どのツールの `inputSchema` の欄も、その動詞が受ける鍵（動詞の表の行）とちょうど一致する。orbe-mcp は本体に依れない
  /// 別ターゲットなので、片側だけ鍵を足すと、AI が書いたその鍵は control に知らない鍵として断られ、control だけに足した
  /// 鍵は AI に見えない。
  func testEveryToolListsExactlyTheKeysItsVerbTakes() throws {
    for tool in ControlProcess.mcpToolsList() {
      let name = try XCTUnwrap(tool["name"] as? String)
      let verb = try XCTUnwrap(ControlServer.verbs[name], "\(name) が動詞の表に無い")
      let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
      XCTAssertEqual(Set(properties?.keys ?? [:].keys), Set(verb.params.keys), name)
    }
  }

  /// どのツールが `inputSchema` に挙げる引数も、control が同じ名前と型で読む。読んだことは、型の違う値を渡してその名前で
  /// 断られることで見る（表にあってハンドラが読まない鍵は断られない）。型違いを省略と読むと、AI が渡した
  /// `get_tab_text` の `scrollback` が既定に倒れ、`spawn` の `cwd` がホームに倒れる。
  func testEveryArgumentTheToolsListIsReadByControl() throws {
    let control = try startControlProcess()
    let tools = ControlProcess.mcpToolsList()
    XCTAssertFalse(tools.isEmpty, "tools/list が空")
    func value(ofKey key: String, type: Any?, matching: Bool) -> Any {
      if key == "workspaceId" { return matching ? UUID().uuidString : 1 }
      switch type as? String {
      case "integer": return matching ? 999_999 : "x"
      case "boolean": return matching ? false : "x"
      case "array": return matching ? [Any]() : "x"
      case "object": return matching ? [String: Any]() : "x"
      default: return matching ? "x" : 1
      }
    }

    for tool in tools {
      let name = try XCTUnwrap(tool["name"] as? String)
      let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
      let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
      let required = schema["required"] as? [String] ?? []
      for (key, property) in properties {
        var arguments: [String: Any] = [:]
        for other in required where other != key {
          arguments[other] = value(ofKey: other, type: properties[other]?["type"], matching: true)
        }
        arguments[key] = value(ofKey: key, type: property["type"], matching: false)

        let call = control.mcpCall(name, arguments)

        XCTAssertTrue(
          call.isError && call.text.contains("invalid \(key)"),
          "\(name) の \(key) を control が読まない: \(call.text)")
      }
    }
  }

  /// AI が MCP だけで、`hasBoard` の workspace（Home の root を知らなくても選べる）のボードのウィジェットを読み・外し・置ける。
  func testBoardWidgetsAreReachableByHasBoard() throws {
    let control = try startControlProcess()
    let workspaces = try XCTUnwrap(
      control.mcpJSON("list_workspaces")["workspaces"] as? [[String: Any]])
    let home = try XCTUnwrap(
      workspaces.first { $0["hasBoard"] as? Bool == true }?["id"] as? String,
      "list_workspaces に hasBoard")
    func kinds(_ tool: String, _ arguments: [String: Any]) -> [String]? {
      (control.mcpJSON(tool, arguments)["widgets"] as? [[String: Any]])?.compactMap {
        $0["kind"] as? String
      }
    }

    XCTAssertEqual(kinds("list_board_widgets", ["workspaceId": home]), ["automation"], "決めていなければ既定")
    XCTAssertEqual(kinds("remove_board_widget", ["workspaceId": home, "kind": "automation"]), [])
    XCTAssertEqual(
      kinds("add_board_widget", ["workspaceId": home, "kind": "automation"]), ["automation"])
  }

  /// 背景 workspace を `activate_workspace` すると、返る `tabIds` の先頭が実際に読めるタブになる
  /// （mount まで届いている）。fixture が背景 WS を必ず作るので、この検証は環境次第で省略されない。
  func testActivateBackgroundWorkspaceYieldsReadableTab() throws {
    let control = try startControlProcess()
    let workspaces = try XCTUnwrap(
      control.mcpJSON("list_workspaces")["workspaces"] as? [[String: Any]])
    let background = try XCTUnwrap(
      workspaces.first { $0["active"] as? Bool == false }, "背景 workspace が fixture に無い")
    let backgroundId = try XCTUnwrap(background["id"] as? String)

    let activated = control.mcpJSON("activate_workspace", ["workspaceId": backgroundId])
    let tabIds = try XCTUnwrap(activated["tabIds"] as? [Int], "activate が tabIds を返さない")
    let tab = try XCTUnwrap(tabIds.first, "activate 後も tabIds が空（タブが mount されていない）")

    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) {
        !tabText(control, tab: tab).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      },
      "activate したタブ \(tab) の画面が空のまま（surface が生成されていない）")
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
