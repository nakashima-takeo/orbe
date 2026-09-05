import Foundation
import XCTest

@testable import Orbe

/// `orb agent prompt` と、`orb agent spawn` / `resume` の ready 待ちを、実バイナリ × 実 `WindowController`
/// × **状態を報告し返す偽 claude** で固定する。偽 claude はタブに注入された `ORBE_REPORT_BIN`
/// （実 `orbe-report`）で idle / working / waiting / done / clear を報告するので、hook 実経路
/// （PTY → 偽 agent → `orbe-report` → `report_agent` → 待機の解決）が 1 本で通る。
///
/// 壊れると何が起きるか: 終了コードは AI とスクリプトが分岐に使う唯一の信号で、done / waiting / clear /
/// 時間切れが混ざると「答えが返った」「質問されている」「セッションが終わった」「まだ終わっていない」を
/// 区別できない。`ready:true` の直後に prompt を送れないなら、spawn → prompt の手順が起動前の PTY に
/// 打ち込んで消える。waiting のエージェントへ text＋Enter が届けば、承認ダイアログの既定選択が確定する。
///
/// prompt / wait の `--timeout-ms` は `waitTimeoutMs` で `ControlProcess.processTimeout`（20 秒）より
/// 十分小さく取る——報告が届かない失敗を既定（1 時間）で黙らせず、子の 124 として見せるため。spawn /
/// resume は既定（30 秒）のまま: 新タブ＋ログインシェル＋agent 起動＋hook 報告を含み、`tabSettleTimeout`
/// （15 秒）より短い上限を被せると負荷時に正当な経路が 124 で落ちる。
final class OrbeCliAgentPromptProcessTests: OrbeTestCase {
  private static let sessionId = "fake-session-0001"
  private static let waitTimeoutMs = 8000

  /// 起動時に idle を報告し、以後は 1 行ごとに working → 止まる状態を報告する偽 claude。
  /// `ask:<q>` は質問文つきの waiting、`slow:<t>` は 10 秒 working のまま、`quit` は clear（SessionEnd。
  /// プロセスは終えない——終えると tab_closed が clear と競い、応答が -32004 に化けうる）。
  /// それ以外は `reply:<行>` を最終応答として done。
  private func stageReportingClaude() throws -> FakeAgent {
    try stageFakeAgent(
      "claude",
      body: """
        printf '{"session_id":"\(Self.sessionId)"}' | "$ORBE_REPORT_BIN" claude idle
        while IFS= read -r line; do
          "$ORBE_REPORT_BIN" claude working </dev/null
          case "$line" in
            ask:*) printf '{"message":"%s"}' "${line#ask:}" | "$ORBE_REPORT_BIN" claude waiting ;;
            slow:*) sleep 10; printf '{"last_assistant_message":"reply:%s"}' "${line#slow:}" \\
              | "$ORBE_REPORT_BIN" claude done ;;
            quit) "$ORBE_REPORT_BIN" claude clear </dev/null ;;
            *) printf '{"last_assistant_message":"reply:%s"}' "$line" | "$ORBE_REPORT_BIN" claude done ;;
          esac
        done
        """)
  }

  private struct ReadySpawn {
    let control: ControlProcess
    let tab: Int
    let spawned: [String: Any]
  }

  /// 偽 claude を仕込んだサーバを立て、ready まで待った spawn の応答とタブ id を返す。
  private func spawnReady(file: StaticString = #filePath, line: UInt = #line) throws -> ReadySpawn {
    _ = try stageReportingClaude()
    let control = try startControlProcess(workspaces: ["main"])
    waitForDetection(control, "claude")
    let spawned = control.orbJSON(["agent", "spawn", "claude"], file: file, line: line)
    let tab = try XCTUnwrap(
      spawned["tabId"] as? Int, "spawn が tabId を返さない", file: file, line: line)
    XCTAssertEqual(
      spawned["ready"] as? Bool, true, "前提: 偽 claude の idle で ready", file: file, line: line)
    return ReadySpawn(control: control, tab: tab, spawned: spawned)
  }

  private func json(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws
    -> [String: Any]
  {
    let data = try XCTUnwrap(text.data(using: .utf8), file: file, line: line)
    return try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any],
      "JSON オブジェクトとして読めない: \(text)", file: file, line: line)
  }

  // MARK: - spawn / resume の ready 待ち

  /// claude は最初の idle を待ってから返り、`ready:true` と idle 報告が運んだ session id を載せる。
  /// 人間向けの行は末尾に ` ready (session <id>)`。resume も同じ形。
  func testSpawnWaitsForTheFirstIdleAndReportsTheSession() throws {
    let ready = try spawnReady()
    let (control, spawned) = (ready.control, ready.spawned)
    XCTAssertEqual(spawned["agentSessionId"] as? String, Self.sessionId, "idle 報告の session id")
    XCTAssertNotNil(spawned["seq"] as? Int, "seq は idle イベントの seq")
    XCTAssertNil(spawned["timedOut"], "ready なら timedOut は無い")

    let plain = control.orb(["agent", "spawn", "claude"])
    XCTAssertEqual(plain.status, 0, "ready で返れば exit 0: \(plain.stderr)")
    XCTAssertTrue(
      plain.stdout.hasPrefix("spawned claude in tab ")
        && plain.stdout.hasSuffix(" ready (session \(Self.sessionId))\n"),
      "人間向けの行は spawned … ready (session <id>): \(plain.stdout)")

    let resumed = control.orbJSON(["agent", "resume", "claude", UUID().uuidString])
    XCTAssertEqual(resumed["ready"] as? Bool, true, "resume も最初の idle を待つ")
    XCTAssertEqual(resumed["agentSessionId"] as? String, Self.sessionId)
  }

  /// idle が来なければ `--timeout-ms` で exit 124。タブは開いているので宛先（tabId）は捨てず、
  /// `ready:false, timedOut:true` で「報告できない agent」と区別する。
  func testSpawnReadyTimeoutExits124ButKeepsTheLaunch() throws {
    _ = try stageFakeAgent("claude")  // 何も報告しない claude
    let control = try startControlProcess(workspaces: ["main"])
    waitForDetection(control, "claude")

    let json = control.orb(["agent", "spawn", "claude", "--timeout-ms", "300", "--json"])
    XCTAssertEqual(json.status, 124, "ready の時間切れは exit 124: \(json.stdout)\(json.stderr)")
    let payload = try self.json(json.stdout)
    XCTAssertNotNil(payload["tabId"] as? Int, "時間切れでも開いたタブの tabId を返す")
    XCTAssertEqual(payload["ready"] as? Bool, false)
    XCTAssertEqual(payload["timedOut"] as? Bool, true)
    XCTAssertNil(payload["agentSessionId"])

    let plain = control.orb(["agent", "spawn", "claude", "--timeout-ms", "300"])
    XCTAssertEqual(plain.status, 124)
    XCTAssertTrue(
      plain.stdout.hasPrefix("spawned claude in tab ") && !plain.stdout.contains(" ready"),
      "spawned 行は出すが ready は付かない: \(plain.stdout)")
    XCTAssertTrue(
      plain.stderr.contains("timed out waiting for the agent to become ready"),
      "理由は stderr へ: \(plain.stderr)")
  }

  // MARK: - prompt の終了コードと出力

  /// done は exit 0 で、非 json の stdout は最終応答の本文だけ。`--json` は `{state, message, seq}`。
  func testPromptExitsZeroAndPrintsTheAgentsReply() throws {
    let ready = try spawnReady()
    let (control, tab) = (ready.control, ready.tab)

    let plain = control.orb([
      "agent", "prompt", "\(tab)", "--text", "hello", "--timeout-ms", "\(Self.waitTimeoutMs)",
    ])
    XCTAssertEqual(plain.status, 0, "done は exit 0: \(plain.stderr)")
    XCTAssertEqual(plain.stdout, "reply:hello\n", "stdout は message 本文のみ")
    XCTAssertTrue(plain.stderr.isEmpty, "成功時に stderr を汚さない: \(plain.stderr)")

    let result = try json(
      control.orb([
        "agent", "prompt", "\(tab)", "--text", "again", "--timeout-ms", "\(Self.waitTimeoutMs)",
        "--json",
      ]).stdout)
    XCTAssertEqual(result["state"] as? String, "done")
    XCTAssertEqual(result["message"] as? String, "reply:again")
    XCTAssertNotNil(result["seq"] as? Int, "seq は done イベントの seq")
  }

  /// `--stdin` は `tab send` と同じ規則で本文を取る。`<tab>` と `--text` / `--stdin` のちょうど一方は
  /// 必須で、欠けは socket に触れる前の usage エラー。
  func testPromptTakesStdinAndRequiresATabAndOneTextSource() throws {
    for args in [
      ["agent", "prompt", "--text", "x"], ["agent", "prompt", "1"],
      ["agent", "prompt", "1", "--text", "x", "--stdin"],
    ] {
      let outcome = ControlProcess.orbWithoutServer(args, env: ["ORBE_TAB": "1"])
      XCTAssertEqual(
        outcome.status, 2, "`\(args.joined(separator: " "))` は usage エラー: \(outcome.stderr)")
    }

    let ready = try spawnReady()
    let (control, tab) = (ready.control, ready.tab)
    let outcome = control.orb(
      ["agent", "prompt", "\(tab)", "--stdin", "--timeout-ms", "\(Self.waitTimeoutMs)"],
      stdin: "from stdin")
    XCTAssertEqual(outcome.status, 0, "--stdin の本文で問える: \(outcome.stderr)")
    XCTAssertEqual(outcome.stdout, "reply:from stdin\n")
  }

  /// waiting は exit 3 で stdout は質問文。waiting のエージェントへの次の prompt は何も送らずに
  /// -32000（exit 1）で拒まれ、状態は waiting のまま。
  func testPromptExitsThreeWhenTheAgentAsksAndRefusesToPromptAWaitingAgent() throws {
    let ready = try spawnReady()
    let (control, tab) = (ready.control, ready.tab)

    let asked = control.orb(
      [
        "agent", "prompt", "\(tab)", "--text", "ask:continue?", "--timeout-ms",
        "\(Self.waitTimeoutMs)",
      ])
    XCTAssertEqual(asked.status, 3, "waiting は exit 3: \(asked.stdout)\(asked.stderr)")
    XCTAssertEqual(asked.stdout, "continue?\n", "stdout は質問文")

    let probe = "REFUSED_" + String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    let refused = control.orb(
      ["agent", "prompt", "\(tab)", "--text", probe, "--timeout-ms", "\(Self.waitTimeoutMs)"])
    XCTAssertEqual(refused.status, 1, "busy は RPC エラー（引数の問題ではない）: \(refused.stdout)")
    XCTAssertTrue(
      refused.stderr.contains("-32000") && refused.stderr.contains("agent busy (state: waiting")
        && refused.stderr.contains("send_key"),
      "拒否の理由と send_key への導線が残る: \(refused.stderr)")
    let listed = control.orbJSON(["tab", "list"])
    XCTAssertEqual(
      (listed["tabs"] as? [[String: Any]])?.first { $0["tabId"] as? Int == tab }?["agentState"]
        as? String, "waiting", "拒まれた prompt はエージェントを動かしていない")

    // 「何も送られていない」を決定論的に見る: 生の enter（waiting への正規の応答）を送り、偽 claude が
    // その空行で done を報告するまで待つ。拒んだ text が先に届いていれば PTY 上で enter より前に
    // 並ぶので、done の時点で画面に写っているはず——写っていなければ送られていない。
    let seq = try XCTUnwrap(listed["seq"] as? Int, "seq の出所")
    let pressed = control.orb(["tab", "key", "\(tab)", "--key", "enter"])
    XCTAssertEqual(pressed.status, 0, "waiting への enter は送れる: \(pressed.stderr)")
    let woke = control.orb(
      [
        "wait", "\(tab)", "--kind", "agent_state", "--value", "done", "--after", "\(seq)",
        "--timeout-ms", "\(Self.waitTimeoutMs)",
      ])
    XCTAssertEqual(woke.status, 0, "enter の空行で偽 claude が done を報告する: \(woke.stderr)")
    XCTAssertFalse(
      control.orb(["tab", "text", "\(tab)", "--scrollback"]).stdout.contains(probe),
      "拒んだ text がタブに書かれている（waiting へ text＋Enter を打つと承認が確定する）")
  }

  /// clear（SessionEnd）は exit 4 で、文言が無いので stdout は空行。
  func testPromptExitsFourWhenTheSessionEnds() throws {
    let ready = try spawnReady()
    let (control, tab) = (ready.control, ready.tab)

    let ended = control.orb(
      ["agent", "prompt", "\(tab)", "--text", "quit", "--timeout-ms", "\(Self.waitTimeoutMs)"])

    XCTAssertEqual(ended.status, 4, "clear は exit 4: \(ended.stdout)\(ended.stderr)")
    XCTAssertEqual(ended.stdout, "\n", "message が無ければ空")
  }

  /// 時間切れは exit 124。非 json は stdout を汚さず stderr に `timed out`、`--json` は result を stdout へ。
  func testPromptTimeoutExits124() throws {
    let ready = try spawnReady()
    let (control, tab) = (ready.control, ready.tab)
    // 1 本目は打ち切り後も 10 秒 working のままで次の prompt が busy に拒まれるので、2 例目は別タブで測る。
    let second = try XCTUnwrap(control.orbJSON(["agent", "spawn", "claude"])["tabId"] as? Int)

    let plain = control.orb([
      "agent", "prompt", "\(tab)", "--text", "slow:a", "--timeout-ms", "500",
    ])
    XCTAssertEqual(plain.status, 124, "時間切れは exit 124: \(plain.stdout)\(plain.stderr)")
    XCTAssertTrue(plain.stdout.isEmpty, "時間切れで stdout を汚さない: \(plain.stdout)")
    XCTAssertTrue(plain.stderr.contains("timed out"), "理由は stderr へ: \(plain.stderr)")

    let json = control.orb(
      ["agent", "prompt", "\(second)", "--text", "slow:b", "--timeout-ms", "500", "--json"])
    XCTAssertEqual(json.status, 124)
    XCTAssertEqual(try self.json(json.stdout)["timedOut"] as? Bool, true, "--json は result をそのまま出す")
  }

  // MARK: - MCP

  /// MCP ブリッジは転送のみで、spawn の `ready` / `agentSessionId` と prompt の `state` / `message` /
  /// `seq` がそのまま tools/call の本文に出る。
  func testSpawnAndPromptAreReachableThroughTheMcpBridge() throws {
    _ = try stageReportingClaude()
    let control = try startControlProcess(workspaces: ["main"])
    waitForDetection(control, "claude")

    let spawned = control.mcpJSON("spawn_agent", ["command": "claude"])
    let tab = try XCTUnwrap(spawned["tabId"] as? Int, "MCP 越しの spawn_agent が tabId を返さない")
    XCTAssertEqual(spawned["ready"] as? Bool, true)
    XCTAssertEqual(spawned["agentSessionId"] as? String, Self.sessionId)

    let answered = control.mcpJSON(
      "prompt_agent", ["tabId": tab, "text": "via mcp", "timeoutMs": Self.waitTimeoutMs])
    XCTAssertEqual(answered["state"] as? String, "done")
    XCTAssertEqual(answered["message"] as? String, "reply:via mcp")
    XCTAssertNotNil(answered["seq"] as? Int)
  }
}
