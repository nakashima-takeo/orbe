import Foundation
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
  /// リポジトリ実体のプラグインパッケージ。このファイル: <repo>/Tests/OrbeTests/...swift → 3 階層上が repo root。
  private static let sourcePackage = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // OrbeTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root
    .appendingPathComponent("app/agent-plugin")

  /// 同梱物レイアウトへプラグインを実体化し、シムの絶対パスを返す。
  /// `hooks/channel` は `materializeStablePlugin()` が書くのと同じ 1 行（自分の bundle ID）。
  private func stagePlugin() throws -> URL {
    let resources = try XCTUnwrap(BundledResources.root, "同梱物の探索根がステージされていない")
    let package = resources.appendingPathComponent("agent-plugin", isDirectory: true)
    try? FileManager.default.removeItem(at: package)
    // copyItem は POSIX permission を保つ（実体化と同じ性質）。
    try FileManager.default.copyItem(at: Self.sourcePackage, to: package)
    let name = try XCTUnwrap(
      AgentPluginInstaller.pluginName(in: package), "プラグイン名を読めない（パッケージが壊れている）")
    let hooks = package.appendingPathComponent("plugins/\(name)/hooks", isDirectory: true)
    try Data("\(StateDir.bundleId)\n".utf8).write(to: hooks.appendingPathComponent("channel"))
    return hooks.appendingPathComponent("orbe-agent-status.sh")
  }

  /// 同梱シムを実 `/bin/sh` で起こす。env はタブから受け取った実値そのままで、親からは継承しない。
  @discardableResult
  private func runShim(
    _ shim: URL, env: [String: String], state: String, stdin: String,
    file: StaticString = #filePath, line: UInt = #line
  ) -> ControlProcess.Outcome {
    let outcome = ControlProcess.run(
      URL(fileURLWithPath: "/bin/sh"), [shim.path, "claude", state], env: env, stdin: stdin,
      file: file, line: line)
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
      // `runShim` は同期で、シムは `exec` で `orbe-report` に置き換わるため、返った時点で報告する
      // 経路なら socket への書き込みは済んでいる。残るのはサーバの受信と main hop だけなので、
      // 短い猶予で足りる（成功側の 5 秒は同じ区間に置いた余裕で、ここより長い必然は無い）。
      XCTAssertFalse(
        waitUntil(0.5) { tab.agentState != nil },
        "\(dropped) が無い呼び出しでタブ状態が動いた（agentState=\(tab.agentState ?? "nil")）")
    }
  }
}
