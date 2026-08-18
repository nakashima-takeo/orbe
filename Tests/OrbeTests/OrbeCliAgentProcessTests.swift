import Foundation
import XCTest

@testable import Orbe

/// `orb agent`（list / spawn / resume）を実バイナリ × 実 `WindowController` で固定する。
///
/// このファイルの合否ゲートは 2 つ。ひとつは「**本当に起動した**」——起動マーカーが実ペインの
/// 画面に現れること。もうひとつは「**背景 workspace を指定しても手元の画面が飛ばない**」
/// ——アクティブ workspace が動かないまま、返った paneId が読めて入力も届くこと。後者は
/// 「作ったタブの surface を前面化せずに起こす」という設計が実際に成立するかを測る唯一の場所で、
/// 成立していなければ `orb agent spawn --workspace <背景>` は「paneId は返るが画面が読めず入力も
/// 届かない paneId」を返す罠になる。
///
/// 検出はマシン依存なので、**必ず偽の実行体と `ShellPATH` の差し替えで固定する**（開発者の Mac には
/// 本物の claude / codex が居る）。assert は仕込んだ `codex` だけを見て、素の検出結果には依らない。
///
/// 重要: 実 `NSWindow` に `SurfaceView` を接続し、実ペインでシェルを走らせる（GhosttyKit 必須）。
final class OrbeCliAgentProcessTests: OrbeTestCase {
  /// 偽 agent の起動マーカー。コマンドの中では 2 つの文字列リテラルに割れているので、
  /// **連結された形はシェルが実際に評価した出力にしか現れない**（入力行の描き返しは目印にならない）。
  private struct FakeAgent {
    let path: String
    let marker: String
  }

  /// 実行可能な偽 agent をテスト専用 dir へ置き、`ShellPATH` をそこ先頭へ差し替える。
  /// `AgentLauncher.init` が構築時に 1 回検出するので、**`startControlProcess()` より前に**呼ぶこと。
  /// `ShellPATH.shared` は `TestIsolation.beginCase` がテストごとに張り直すので戻しは要らない。
  private func stageFakeAgent(_ command: String) throws -> FakeAgent {
    let caseDir = try XCTUnwrap(TestIsolation.caseDir, "テスト専用ディレクトリが配られていない")
    let dir = caseDir.appendingPathComponent("fake-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let marker = "L4AGENT_" + String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    let split = marker.replacingOccurrences(of: "_", with: "\"\"_")  // L4AGENT""_xxxx
    let executable = dir.appendingPathComponent(command)
    // 引数もそのまま出す（resume が `resume <id>` を渡したことを画面で確かめるため）。
    // 起動しっぱなしにしないと surface が即閉じてペインごと消える。
    try """
    #!/bin/sh
    echo "\(split) $*"
    exec /bin/cat
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let fakeDir = dir.path
    ShellPATH.shared = ShellPATH(probe: { "\(fakeDir):/usr/bin:/bin" })
    return FakeAgent(path: executable.path, marker: marker)
  }

  /// 偽 agent の検出完了を待つ（`AgentCatalog.refresh` は非同期）。
  private func waitForDetection(_ control: ControlProcess, _ command: String) {
    XCTAssertTrue(
      waitUntil(ControlProcess.paneSettleTimeout) {
        control.target.agentLauncher.detectedCommands.contains(command)
      }, "偽 \(command) が検出されない（ShellPATH の差し替えが効いていない）")
  }

  /// ペインの画面に文字列が `times` 回以上現れるまで待つ。読むのは実バイナリの `orb pane text`。
  @discardableResult
  private func waitForPaneText(
    _ control: ControlProcess, pane: Int, contains needle: String, times: Int = 1,
    file: StaticString = #filePath, line: UInt = #line
  ) -> String {
    var text = ""
    let seen = waitUntil(ControlProcess.paneSettleTimeout) {
      text = control.orb(["pane", "text", "\(pane)", "--scrollback"]).stdout
      return text.components(separatedBy: needle).count - 1 >= times
    }
    XCTAssertTrue(
      seen, "ペイン \(pane) に \"\(needle)\" が \(times) 回以上現れない: \(text)", file: file, line: line)
    return text
  }

  /// `orb agent list` が検出済み agent を command＋絶対 path で出す。
  func testAgentListReportsDetectedAgentWithResolvedPath() throws {
    let fake = try stageFakeAgent("codex")
    let control = try startControlProcess(workspaces: ["main"])
    waitForDetection(control, "codex")

    let agents = try XCTUnwrap(
      control.orbJSON(["agent", "list"])["agents"] as? [[String: Any]], "agent list: agents を返さない")
    let codex = try XCTUnwrap(
      agents.first { $0["command"] as? String == "codex" }, "仕込んだ codex が出ない: \(agents)")
    XCTAssertEqual(codex["path"] as? String, fake.path, "path は解決済みの絶対パス")

    // 人間向けは `command\tpath` の行。
    let plain = control.orb(["agent", "list"])
    XCTAssertEqual(plain.status, 0, "agent list は exit 0: \(plain.stderr)")
    XCTAssertTrue(
      plain.stdout.contains("codex\t\(fake.path)"), "人間向けは command\\tpath: \(plain.stdout)")
  }

  /// `orb agent spawn <agent>` がアクティブ workspace の新タブでエージェントを**実際に起動する**。
  /// 戻り値の 4 つ（paneId / tabId / workspaceId / agent）が揃うことも同時に見る。
  func testAgentSpawnLaunchesTheAgentInANewTab() throws {
    let fake = try stageFakeAgent("codex")
    let control = try startControlProcess(workspaces: ["main"])
    waitForDetection(control, "codex")

    // 「新タブ」を測るには spawn 前の tab 集合が要る。tabId の非 nil だけを見ると、既存タブの
    // 使い回しや split への化けを素通しする（開くのは常に新しいタブ、が Orbe の看板の振る舞い）。
    let tabsBefore = Set(
      try XCTUnwrap(control.orbJSON(["pane", "list"])["panes"] as? [[String: Any]])
        .compactMap { $0["tabId"] as? Int })

    let spawned = control.orbJSON(["agent", "spawn", "codex"])
    let pane = try XCTUnwrap(spawned["paneId"] as? Int, "spawn_agent が paneId を返さない")
    let tabId = try XCTUnwrap(spawned["tabId"] as? Int, "spawn_agent は tabId も返す")
    XCTAssertFalse(tabsBefore.contains(tabId), "既存タブを使い回さず新タブに生える")
    let workspaceId = try XCTUnwrap(spawned["workspaceId"] as? Int, "spawn_agent は workspaceId も返す")
    let agent = try XCTUnwrap(spawned["agent"] as? [String: Any], "spawn_agent は agent を返す")
    XCTAssertEqual(agent["command"] as? String, "codex")
    XCTAssertEqual(agent["path"] as? String, fake.path, "起動に使うのは解決済み絶対パス")
    XCTAssertNil(spawned["sessionId"], "実 session ID は返さない（list_panes / wait が出所）")

    waitForPaneText(control, pane: pane, contains: fake.marker)

    let panes = try XCTUnwrap(control.orbJSON(["pane", "list"])["panes"] as? [[String: Any]])
    XCTAssertEqual(
      panes.first { $0["paneId"] as? Int == pane }?["workspaceId"] as? Int, workspaceId,
      "返った workspaceId は実際の所属 workspace")
  }

  /// `<agent>` 省略時は対象 workspace の実効 `default-agent` を解く（GUI の Cmd+Shift+C と同じ 1 規則）。
  /// 設定を明示するのは、素の検出結果（開発者の Mac に居る本物）に依存させないため。
  func testAgentSpawnWithoutArgumentUsesTheWorkspaceDefaultAgent() throws {
    let fake = try stageFakeAgent("codex")
    let control = try startControlProcess(workspaces: ["main"])
    waitForDetection(control, "codex")

    let activeId = try XCTUnwrap(
      (control.orbJSON(["ws", "list"])["workspaces"] as? [[String: Any]])?
        .first(where: { $0["active"] as? Bool == true })?["id"] as? Int)
    let written = control.orb(
      ["config", "set", "default-agent", "codex", "--workspace", "\(activeId)"])
    XCTAssertEqual(written.status, 0, "default-agent を WS へ書けない: \(written.stderr)")

    let spawned = control.orbJSON(["agent", "spawn"])
    XCTAssertEqual(
      (spawned["agent"] as? [String: Any])?["command"] as? String, "codex",
      "省略時は対象 WS の実効 default-agent が起きる")
    waitForPaneText(
      control, pane: try XCTUnwrap(spawned["paneId"] as? Int), contains: fake.marker)
  }

  /// 解くのは **対象** workspace の実効設定で、アクティブ WS のではない。ここがこの API と GUI の
  /// Cmd+Shift+C の唯一の違いなので、対象 ≠ アクティブ・両者に別の `default-agent` という形で測る
  /// ——同一 WS で測ると `current.settingsOverride` と書き違えても緑のまま通る。
  func testAgentSpawnWithoutArgumentResolvesTheTargetWorkspaceNotTheActiveOne() throws {
    _ = try stageFakeAgent("claude")
    let codex = try stageFakeAgent("codex")
    let control = try startControlProcess(workspaces: ["main", "background"])
    waitForDetection(control, "claude")
    waitForDetection(control, "codex")

    let list = try XCTUnwrap(control.orbJSON(["ws", "list"])["workspaces"] as? [[String: Any]])
    let activeId = try XCTUnwrap(
      list.first(where: { $0["active"] as? Bool == true })?["id"] as? Int, "アクティブ WS が無い")
    let backgroundId = try XCTUnwrap(
      list.first(where: { $0["active"] as? Bool == false })?["id"] as? Int, "背景 WS が無い")
    for (id, agent) in [(activeId, "claude"), (backgroundId, "codex")] {
      let written = control.orb(
        ["config", "set", "default-agent", agent, "--workspace", "\(id)"])
      XCTAssertEqual(written.status, 0, "default-agent を WS \(id) へ書けない: \(written.stderr)")
    }

    let spawned = control.orbJSON(["agent", "spawn", "--workspace", "\(backgroundId)"])
    XCTAssertEqual(
      (spawned["agent"] as? [String: Any])?["command"] as? String, "codex",
      "アクティブ WS の default-agent（claude）ではなく対象 WS の設定で解く")
    waitForPaneText(
      control, pane: try XCTUnwrap(spawned["paneId"] as? Int), contains: codex.marker)
  }

  /// **背景 workspace への spawn は手元の画面を奪わない。** そのうえで返った paneId は生きている。
  ///
  /// (a) アクティブ workspace が変わらない、(b) 画面が読める＝surface が起きている、
  /// (c) 入力が本文もキーも届く、(d) surface が実サイズで生まれている。4 つが揃って初めて「前面化せずに
  /// mount した」と言える。どれか 1 つでも欠けると、`--workspace <背景>` は使えない paneId を
  /// 返すだけの罠になる——(d) が欠けた場合だけは静かで、返る画面の折り返し幅だけが
  /// libghostty 既定サイズのまま狂う（その workspace を前面化するまで直らない）。
  func testAgentSpawnIntoBackgroundWorkspaceKeepsTheForegroundAndStaysUsable() throws {
    let fake = try stageFakeAgent("codex")
    let control = try startControlProcess(workspaces: ["main", "background"])
    waitForDetection(control, "codex")

    let before = try XCTUnwrap(control.orbJSON(["ws", "list"])["workspaces"] as? [[String: Any]])
    let activeId = try XCTUnwrap(
      before.first(where: { $0["active"] as? Bool == true })?["id"] as? Int, "アクティブ WS が無い")
    let backgroundId = try XCTUnwrap(
      before.first(where: { $0["active"] as? Bool == false })?["id"] as? Int, "背景 WS が無い")

    let spawned = control.orbJSON(
      ["agent", "spawn", "codex", "--workspace", "\(backgroundId)"])
    let pane = try XCTUnwrap(spawned["paneId"] as? Int, "背景 WS への spawn が paneId を返さない")
    XCTAssertEqual(
      spawned["workspaceId"] as? Int, backgroundId, "指定した背景 WS に生える")

    // (a) 画面が飛んでいない。
    let after = try XCTUnwrap(control.orbJSON(["ws", "list"])["workspaces"] as? [[String: Any]])
    XCTAssertEqual(
      after.first(where: { $0["active"] as? Bool == true })?["id"] as? Int, activeId,
      "背景 WS への spawn がアクティブ WS を奪っている（前面化しないのが契約）")
    let background = try XCTUnwrap(after.first { $0["id"] as? Int == backgroundId })
    XCTAssertEqual(background["active"] as? Bool, false, "背景のまま")
    XCTAssertEqual(
      background["activated"] as? Bool, true,
      "新規タブの off-screen materialize は workspace の現在状態に反映する")

    // (b) 背景でも surface が生きて描いている。
    waitForPaneText(control, pane: pane, contains: fake.marker)

    // (c) 入力も届く。`pane send` と `pane key` の両方を通す——送るのが本文だけなら、画面に
    // 現れた probe は tty のエコーかもしれず、ペインの中のプロセスが受け取った証拠にならない。
    // 偽 agent は `cat` で、行が完成する（＝enter が届く）まで 1 バイトも返さないので、probe が
    // **2 回**現れることが enter の到達そのものを指す（エコー 1 回 ＋ `cat` の反響 1 回）。
    let probe = "PING_" + String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    let sent = control.orb(["pane", "send", "\(pane)", "--text", probe])
    XCTAssertEqual(sent.status, 0, "背景ペインへの send_text が失敗した: \(sent.stderr)")
    waitForPaneText(control, pane: pane, contains: probe)
    let pressed = control.orb(["pane", "key", "\(pane)", "--key", "enter"])
    XCTAssertEqual(pressed.status, 0, "背景ペインへの send_key が失敗した: \(pressed.stderr)")
    waitForPaneText(control, pane: pane, contains: probe, times: 2)

    // (d) surface は実サイズで生まれている。葉のサイズを配るのは window の display サイクルで
    // 走る `SurfaceScrollView.layout()` だけなので、同じ turn で detach する起こし方は
    // レイアウトを同期で確定させない限り 0 サイズのまま surface を作ってしまう。
    let view = try XCTUnwrap(
      control.target.controlResolvePane(pane), "返った paneId がペインに解決できない")
    // 相対比較なので、先に基準側が非ゼロであることを言う——0 同士の一致は、まさにここで
    // 検出したい失敗（ゼロ面積で生まれた surface）と区別がつかない。
    XCTAssertGreaterThan(
      control.target.model.content.bounds.width, 0, "前提: content が実サイズを持つ")
    XCTAssertEqual(
      view.bounds.size, control.target.model.content.bounds.size,
      "背景 WS のペインが実サイズで起きていない（pty が libghostty 既定サイズのまま残る）")
  }

  /// `orb agent resume` が resume 形の起動コマンド（`codex resume <id>`）で起こす。
  func testAgentResumeLaunchesWithTheResumeCommand() throws {
    let fake = try stageFakeAgent("codex")
    let control = try startControlProcess(workspaces: ["main"])
    waitForDetection(control, "codex")

    let sessionId = UUID().uuidString
    let resumed = control.orbJSON(["agent", "resume", "codex", sessionId])
    let pane = try XCTUnwrap(resumed["paneId"] as? Int, "resume_agent が paneId を返さない")
    XCTAssertEqual((resumed["agent"] as? [String: Any])?["command"] as? String, "codex")
    XCTAssertNil(resumed["sessionId"], "渡した sessionId を反響しない")

    let text = waitForPaneText(control, pane: pane, contains: fake.marker)
    XCTAssertTrue(
      text.contains("resume \(sessionId)"),
      "resume の引数が agent へ渡っていない（素の起動に化けている）: \(text)")
  }

  /// 拒否側。CLI は agent 名も session ID の文字集合も複製せず、control が -32602 / -32004 で弾く
  /// （どれも exit 1＝「引数を直せ」ではなく「Orbe が拒否した」）。
  func testAgentLaunchRejectionsComeFromControl() throws {
    _ = try stageFakeAgent("codex")
    let control = try startControlProcess(workspaces: ["main"])
    waitForDetection(control, "codex")

    let unknown = control.orb(["agent", "spawn", "nosuch"])
    XCTAssertEqual(unknown.status, 1, "未検出 agent は RPC エラー: \(unknown.stdout)\(unknown.stderr)")
    XCTAssertTrue(
      unknown.stderr.contains("-32602") && unknown.stderr.contains("agent not detected"),
      "未検出 agent の理由が残る: \(unknown.stderr)")

    // session ID の安全文字検証は `AgentCatalog.resumeCommand` の再利用（CLI に写さない）。
    let injected = control.orb(["agent", "resume", "codex", "a;rm -rf /"])
    XCTAssertEqual(injected.status, 1, "不正 session ID は RPC エラー")
    XCTAssertTrue(
      injected.stderr.contains("-32602") && injected.stderr.contains("invalid sessionId"),
      "不正 session ID の理由が残る: \(injected.stderr)")

    // 未知 workspaceId は**フォールバックしない**（既存 spawn の「黙ってアクティブへ」を継がない）。
    let stray = control.orb(["agent", "spawn", "codex", "--workspace", "999999"])
    XCTAssertEqual(stray.status, 1, "未知 workspaceId は RPC エラー")
    XCTAssertTrue(
      stray.stderr.contains("-32004") && stray.stderr.contains("workspace not found"),
      "未知 workspaceId はアクティブへ逸れず落ちる: \(stray.stderr)")
  }

  /// MCP へも同じ起動口が出ている（AI から駆動する経路が socket 専用に落ちていない）。
  func testSpawnAgentIsReachableThroughTheMcpBridge() throws {
    let fake = try stageFakeAgent("codex")
    let control = try startControlProcess(workspaces: ["main"])
    waitForDetection(control, "codex")

    let spawned = control.mcpJSON("spawn_agent", ["command": "codex"])
    let pane = try XCTUnwrap(spawned["paneId"] as? Int, "MCP 越しの spawn_agent が paneId を返さない")
    XCTAssertEqual((spawned["agent"] as? [String: Any])?["path"] as? String, fake.path)
    waitForPaneText(control, pane: pane, contains: fake.marker)
  }
}
