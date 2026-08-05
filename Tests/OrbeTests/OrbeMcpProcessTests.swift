import XCTest

@testable import Orbe

/// 実 `orbe-mcp` を子プロセスで起こし、MCP の `tools/call` → control.sock → 実 `WindowController`
/// までの導通と、L3 が固定できなかった `get_pane_text` の `scrollback` を測る。
///
/// 壊れると何が起きるか: MCP ブリッジがツール名を control のメソッドへ載せ替えられなくなっても、
/// `isError` の畳み込みが消えても、実ペインへの注入・読み取りが no-op に倒れても、どのテストも
/// 落ちなくなる。AI から Orbe を駆動する MCP の口が黙って死に、気づくのは人が手で触ったときになる。
///
/// 重要: 実 `NSWindow` に `SurfaceView` を接続し、実ペインでシェルを走らせる（GhosttyKit 必須）。
/// ヘッドレスな純ロジック検証ではない。
final class OrbeMcpProcessTests: OrbeTestCase {
  /// `list_panes` からフォーカス中（無ければ先頭）のペイン id を読む。
  private func livePaneId(_ control: ControlProcess) throws -> Int {
    let panes = try XCTUnwrap(
      control.mcpJSON("list_panes")["panes"] as? [[String: Any]], "list_panes が panes を返さない")
    let live = panes.first { $0["focused"] as? Bool == true } ?? panes.first
    return try XCTUnwrap(live?["paneId"] as? Int, "ペインが 1 つも無い")
  }

  /// ペインへ 1 行流して実行させる（`send_text` はペースト相当で自己実行しないため enter を別送する）。
  private func runInPane(_ control: ControlProcess, pane: Int, command: String) {
    XCTAssertFalse(
      control.mcpCall("send_text", ["paneId": pane, "text": command]).isError, "send_text が失敗した")
    XCTAssertFalse(
      control.mcpCall("send_key", ["paneId": pane, "key": "enter"]).isError, "send_key が失敗した")
  }

  private func paneText(_ control: ControlProcess, pane: Int, scrollback: Bool = false) -> String {
    control.mcpJSON("get_pane_text", ["paneId": pane, "scrollback": scrollback])["text"] as? String
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
  private func waitForExecution(_ control: ControlProcess, pane: Int, marker: String) -> Bool {
    waitUntil(ControlProcess.paneSettleTimeout) {
      paneText(control, pane: pane, scrollback: true).contains(marker)
    }
  }

  /// `send_text` ＋ `send_key enter` でペインのシェルが実際にコマンドを**実行**する
  /// （`send_text` はペースト相当なので、enter を別送しなければプロンプトに留まったままになる）。
  func testSendTextAndEnterExecutesInPane() throws {
    let control = try startControlProcess()
    let pane = try livePaneId(control)
    let probe = executionProbe()

    runInPane(control, pane: pane, command: probe.command)

    XCTAssertTrue(
      waitForExecution(control, pane: pane, marker: probe.marker),
      "enter を送ってもコマンドが実行されていない: \(paneText(control, pane: pane, scrollback: true))")
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

  /// 背景 workspace を `activate_workspace` すると、返る `paneIds` の先頭が実際に読めるペインになる
  /// （mount まで届いている）。fixture が背景 WS を必ず作るので、この検証は環境次第で省略されない。
  func testActivateBackgroundWorkspaceYieldsReadablePane() throws {
    let control = try startControlProcess()
    let workspaces = try XCTUnwrap(
      control.mcpJSON("list_workspaces")["workspaces"] as? [[String: Any]])
    let background = try XCTUnwrap(
      workspaces.first { $0["active"] as? Bool == false }, "背景 workspace が fixture に無い")
    let backgroundId = try XCTUnwrap(background["id"] as? Int)

    let activated = control.mcpJSON("activate_workspace", ["workspaceId": backgroundId])
    let paneIds = try XCTUnwrap(activated["paneIds"] as? [Int], "activate が paneIds を返さない")
    let pane = try XCTUnwrap(paneIds.first, "activate 後も paneIds が空（タブが mount されていない）")

    XCTAssertTrue(
      waitUntil(ControlProcess.paneSettleTimeout) {
        !paneText(control, pane: pane).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      },
      "activate したペイン \(pane) の画面が空のまま（surface が生成されていない）")
  }

  /// 未知の `workspaceId` は control のエラーが MCP の `isError` へ畳まれ、本文に理由が残る。
  func testActivateUnknownWorkspaceIsReportedAsError() throws {
    let control = try startControlProcess()
    let call = control.mcpCall("activate_workspace", ["workspaceId": 999_999])
    XCTAssertTrue(call.isError, "未知 workspaceId は isError:true になる")
    XCTAssertTrue(
      call.text.contains("workspace not found"), "error 本文に理由が残る: \(call.text)")
  }

  /// `get_pane_text` の `scrollback` が効く。可視範囲を溢れる出力を流すと、`true` の結果は
  /// `false` の結果を真に含む（`false` で消えた古い行が `true` にだけ残る）。
  /// Fake target では `controlReadText` が surface 不在で nil を返すため、実 surface でしか測れない。
  func testGetPaneTextScrollbackIncludesHistoryBeyondViewport() throws {
    let control = try startControlProcess()
    let pane = try livePaneId(control)

    let probe = executionProbe()
    runInPane(control, pane: pane, command: "seq 1 200; \(probe.command)")
    XCTAssertTrue(
      waitForExecution(control, pane: pane, marker: probe.marker), "seq の出力が出切らない")

    let visible = paneText(control, pane: pane)
    let full = paneText(control, pane: pane, scrollback: true)
    XCTAssertFalse(
      visible.contains("\n1\n"), "可視範囲には最初の行が残らない（画面より長い出力を流した前提）")
    XCTAssertTrue(full.contains("\n1\n"), "scrollback:true は画面外へ流れた行を含む")
    XCTAssertGreaterThan(
      full.count, visible.count, "scrollback:true の方が長い（両者が同じなら真偽が効いていない）")
  }
}
