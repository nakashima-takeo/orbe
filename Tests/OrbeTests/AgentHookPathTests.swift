import Foundation
import OrbeTestSupport
import XCTest

@testable import Orbe

/// エージェント hook の実経路を継ぎ目ごと 1 本で通す——タブへ注入された env の**実値**で
/// 同梱シムを実 `/bin/sh` から起こし、`orbe-report` が `report_agent` を組み立て、実
/// `ControlServer` を通って発信元タブの状態が変わるまで。
///
/// 区間ごとの検証は既に在る（シムのチャネルゲートは `AgentShimChannelGateTests`、stdin の解釈は
/// `ReportLogicTests`、`report_agent` の wire は L3、タブ状態の上書き規律は
/// `WindowControllerReportAgentTests`）。残る穴は継ぎ目そのもので、注入された env が実際に
/// シムと `orbe-report` を正しいタブへ導くかは、どの区間テストも見ていない。
///
/// 壊れると何が起きるか: エージェントの状態がタブに一切出なくなる。しかもどの実行体も
/// エラーを出さない——シムは env が欠ければ黙って exit 0、`orbe-report` は接続できなくても exit 0。
final class AgentHookPathTests: OrbeTestCase {
  private func stagePlugin() throws -> URL {
    try ControlProcess.stagePlugin().appendingPathComponent("hooks/orbe-agent-status.sh")
  }

  /// 同梱シムを実 `/bin/sh` で起動する。env はタブから受け取った実値そのままで、親からは継承しない。`detached` なら
  /// 制御端末を持たない親から起動する。
  @discardableResult
  private func runShim(
    _ shim: URL, agent: String = "claude", env: [String: String], state: String, stdin: String,
    detached: Bool = false, file: StaticString = #filePath, line: UInt = #line
  ) -> ControlProcess.Outcome {
    let sh = URL(fileURLWithPath: "/bin/sh")
    let args = [shim.path, agent, state]
    let outcome =
      detached
      ? ControlProcess.runDetached(
        sh, args, env: env, stdin: stdin, child: .newSession, file: file, line: line)
      : ControlProcess.run(sh, args, env: env, stdin: stdin, file: file, line: line)
    XCTAssertEqual(
      outcome.status, 0, "シムは常に exit 0（hook を落とさない）: \(outcome.stderr)", file: file, line: line)
    return outcome
  }

  /// タブの実 env を取る。`PATH` だけ明示で種を置く——`prependBundledBin` は空なら親プロセスの
  /// `PATH` を読むため、置かないと env に親の値が混ざる。
  private func tabEnv(_ tab: TerminalTab) -> [String: String] {
    var env = ["PATH": "/usr/bin:/bin"]
    OrbeRuntimeEnv.inject(into: &env, tabId: tab.id)
    return env
  }

  private func firstTab(_ control: ControlProcess) throws -> TerminalTab {
    try XCTUnwrap(control.target.current.tabs.first, "タブが無い")
  }

  /// 注入 env → 同梱シム → `orbe-report` → `report_agent` → タブ状態、が 1 本で通る。
  func testInjectedEnvCarriesHookReportToItsOwnTab() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let shim = try stagePlugin()
    let tab = try firstTab(control)
    let env = tabEnv(tab)

    // 継ぎ目の材料。ここが欠けた時点で以降は全部 no-op になるので、先に実値を固定する。
    XCTAssertEqual(env["ORBE_TAB"], String(tab.id), "自タブ id が報告元として注入される")
    XCTAssertEqual(env["ORBE_SOCK"], ControlServer.shared.socketPath, "自インスタンスの socket が注入される")
    XCTAssertEqual(
      env["ORBE_REPORT_BIN"], BundledResources.root?.appendingPathComponent("bin/orbe-report").path,
      "同梱 orbe-report の絶対パスが注入される")
    XCTAssertEqual(env["ORBE_BUNDLE_ID"], StateDir.bundleId, "シムのチャネルゲートが突き合わせる identity")

    runShim(shim, env: env, state: "waiting", stdin: #"{"session_id":"s-1","message":"許可しますか"}"#)

    XCTAssertTrue(
      waitUntil(5) { tab.agentState == "waiting" },
      "hook の報告がタブ \(tab.id) に届かない（agentState=\(tab.agentState ?? "nil")）")
    XCTAssertEqual(
      tab.agentSlot.session?.sessionId, "s-1", "stdin の session_id が resume 鍵としてタブまで届く")
  }

  /// タブの中の agent が起こした hook の報告だけが、会話へ貼ってよい前面を覚えさせる。同じタブを名乗っても、タブの
  /// 端末の外（tmux のペイン・ここではテストのプロセス）から来た報告は前面を覚えさせない。
  func testOnlyAHookFromTheTabsForegroundLetsTheConversationTakeInput() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let shim = try stagePlugin()
    let tabId = try XCTUnwrap(
      control.target.controlSpawn(
        workspaceId: nil, cwd: nil,
        command: "/bin/sh -c 'echo {} | /bin/sh \(shim.path) claude idle; exec /bin/sleep 600'"))
    let tab = try XCTUnwrap(control.target.controlResolveTab(tabId))

    XCTAssertTrue(
      waitUntil(5) { tab.acceptsConversationInput },
      "タブの前面の hook の報告で貼ってよくならない（agentState=\(tab.agentState ?? "nil")）")

    runShim(shim, env: tabEnv(tab), state: "idle", stdin: "{}")
    XCTAssertTrue(
      waitUntil(5) { !tab.acceptsConversationInput }, "タブの外から来た報告で前面を覚えたまま")
  }

  /// タブの端末で動く codex（デーモンを使わない codex）が実行した hook は、そのタブに状態とセッション ID を付ける。codex と
  /// 同じく、このテストは hook をタブのシェルの子として新しいセッションの先頭で起動する。間のシェルが hook のコマンドを exec で置き換える
  /// 場合も、置き換えない場合（ログイン設定の EXIT の trap など）も、報告の結果は同じ。
  func testCodexHookFromTheTabsTerminalReportsToItsOwnTabWhetherOrNotTheShellExecs() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let shim = try stagePlugin()
    let hook = ["/bin/sh", shim.path, "codex", "working"]
    let shapes = [
      ("間のシェルが exec する", hook),
      ("間のシェルが exec しない", ["/bin/sh", "-c", hook.map(ShellWord.quoted).joined(separator: " ") + "; :"]),
    ]
    for (index, (shape, words)) in shapes.enumerated() {
      let script = TestScratch.caseDir.appendingPathComponent("codex-hook-\(index).sh")
      try Data(
        """
        printf '%s' '{"session_id":"s-\(index)"}' | \(ControlProcess.shellCommand(words, as: .newSession))
        exec /bin/sleep 600
        """.utf8
      ).write(to: script)
      let tabId = try XCTUnwrap(
        control.target.controlSpawn(
          workspaceId: nil, cwd: nil, command: "/bin/sh \(ShellWord.quoted(script.path))"))
      let tab = try XCTUnwrap(control.target.controlResolveTab(tabId))

      XCTAssertTrue(
        waitUntil(ControlProcess.tabSettleTimeout) { tab.agentState == "working" },
        "\(shape): タブ上の codex が実行した hook の報告がそのタブに届かない（agentState=\(tab.agentState ?? "nil")）")
      XCTAssertEqual(
        tab.agentSlot.session, AgentSession(command: "codex", sessionId: "s-\(index)"), shape)
    }
  }

  /// 端末から切り離されたプロセス（デーモン経由の codex）が実行した codex の hook は、タブの env を受け継いでいても
  /// 報告しない。同じ起動方法の claude の hook は報告する——判定は codex だけに掛かる。
  func testCodexHookFromADetachedProcessReportsNothingEvenWithTheTabsEnv() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let shim = try stagePlugin()
    let tab = try firstTab(control)
    let env = tabEnv(tab)

    runShim(shim, agent: "codex", env: env, state: "working", stdin: "{}", detached: true)
    XCTAssertFalse(
      waitUntil(0.5) { tab.agentState != nil },
      "切り離した codex の hook でタブ状態が動いた（agentState=\(tab.agentState ?? "nil")）")

    runShim(shim, agent: "claude", env: env, state: "working", stdin: "{}", detached: true)
    XCTAssertTrue(
      waitUntil(5) { tab.agentState == "working" },
      "切り離した claude の hook の報告が届かない（agentState=\(tab.agentState ?? "nil")）")
  }

  /// Orbe 外の端末（`ORBE_TAB` / `ORBE_SOCK` が無い）で走った hook はタブを一切動かさない。
  /// hook は Orbe を知らないセッションでも走るため、ここが no-op でないと無関係な端末の活動が
  /// タブの状態として現れる。
  func testHookOutsideOrbeTabLeavesTabStateUntouched() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let shim = try stagePlugin()
    let tab = try firstTab(control)
    let env = tabEnv(tab)

    for dropped in ["ORBE_TAB", "ORBE_SOCK"] {
      var partial = env
      partial.removeValue(forKey: dropped)
      runShim(shim, env: partial, state: "working", stdin: "{}")
      // `runShim` は同期で、シムは `exec` で `orbe-report` に置き換わり、`orbe-report` は Orbe の応答まで
      // 待つため、返った時点で報告する経路なら適用まで済んでいる。短い猶予で足りる。
      XCTAssertFalse(
        waitUntil(0.5) { tab.agentState != nil },
        "\(dropped) が無い呼び出しでタブ状態が動いた（agentState=\(tab.agentState ?? "nil")）")
    }
  }
}
