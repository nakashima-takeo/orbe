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
    XCTAssertTrue(
      description(try tool("list_intakes")).contains("新しい順に \(Intake.retainedRuns) 件まで。"),
      "回の記録を残す件数を写す")
  }

  /// `tools/list` に出る全ツールが control の method として通る。ブリッジはツール名をそのまま method 名へ
  /// 載せ替えるので、片側だけ綴りが変わると tools/list は緑のまま呼び出しだけが `method not found` で死ぬ。
  /// 引数は実在しない宛先・最短の待ちに向ける（届いたかだけを見るので、成否は問わない）。
  ///
  /// control の拒否は MCP の `isError` へ畳まれ、本文に理由が残る——畳まれなければ AI は失敗を成功と読む。
  func testEveryListedToolReachesControlAndRejectionsBecomeIsError() throws {
    let control = try startControlProcess()
    let names = ControlProcess.mcpToolsList().compactMap { $0["name"] as? String }
    XCTAssertFalse(names.isEmpty, "tools/list が空")
    let nowhere: [String: Any] = [
      "tabId": 999_999, "workspaceId": 999_999, "taskId": 999_999, "timeoutMs": 1,
    ]
    for name in names {
      let call = control.mcpCall(name, nowhere)
      XCTAssertFalse(
        call.text.hasPrefix("method not found"), "\(name) が control の method として通らない: \(call.text)")
    }

    let rejected = control.mcpCall("activate_workspace", ["workspaceId": 999_999])
    XCTAssertTrue(rejected.isError, "control の拒否は isError:true になる")
    XCTAssertTrue(
      rejected.text.contains("workspace not found"), "error 本文に理由が残る: \(rejected.text)")
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
