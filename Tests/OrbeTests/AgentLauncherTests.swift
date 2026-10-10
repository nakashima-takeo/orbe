import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 起動時のプラグイン同期——導入済みの利用者には、同梱プラグインの中身が変わった起動でだけ
/// `install.sh` が裏で走る。
///
/// 壊れると何が起きるか: 中身が変わっても codex / agy が古いコピー（MCP 定義の無い版など）を読み続ける。
/// 逆に、変わっていない起動でも毎回入れ直し、そのたびに agy からプラグインが一瞬外れる。
final class AgentLauncherTests: OrbeTestCase {
  private var bundled: URL!  // 同梱プラグイン（`.app` の Resources/agent-plugin に当たる）
  private var runs: URL!  // fake install.sh が起こされるたびに 1 行足す

  override func setUpWithError() throws {
    bundled = try XCTUnwrap(BundledResources.root).appendingPathComponent("agent-plugin")
    runs = TestScratch.caseDir.appendingPathComponent("install-runs.log")
    try write(
      "install.sh",
      """
      #!/bin/sh
      echo run >> "\(runs.path)"
      echo "start claude"
      echo "installed claude"
      """)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: bundled.appendingPathComponent("install.sh").path)
    try write("plugins/orbe-agent-dev/mcp_config.json", "{}")
    AppStatePersistence.save(AppStateFile(agentPluginsInstalled: true))
  }

  private func write(_ rel: String, _ text: String) throws {
    let url = bundled.appendingPathComponent(rel)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private var runCount: Int {
    ((try? String(contentsOf: runs, encoding: .utf8)) ?? "").split(separator: "\n").count
  }

  func testInstallerRunsOnlyOnLaunchesWhosePackageContentsChanged() throws {
    let launcher = AgentLauncher()
    launcher.registersPlugin = true

    launcher.syncAgentPluginOnLaunch()
    pumpMain(until: { AgentPluginInstaller.registeredDigest != nil }, "登録の記録が無い起動で入れ直す")
    let first = AgentPluginInstaller.registeredDigest

    launcher.syncAgentPluginOnLaunch()  // 同じ中身のまま起動し直す

    try write("plugins/orbe-agent-dev/mcp_config.json", #"{"mcpServers":{}}"#)
    launcher.syncAgentPluginOnLaunch()
    pumpMain(until: { AgentPluginInstaller.registeredDigest != first }, "中身の変わった起動で入れ直す")

    XCTAssertEqual(runCount, 2, "同じ中身の起動では走らない")
  }

  /// 隔離起動は実体化だけをして、CLI への登録（install.sh）も、そのためのオンボーディングもしない。
  ///
  /// 壊れると何が起きるか: 検証用に起こした Orbe が利用者の claude / codex / agy の登録先を自分の一時フォルダへ向け替え、
  /// codex / agy のコピーを検証中の中身で上書きする。片付けた後には利用者の agent から状態追跡と MCP が消える。
  func testIsolatedLauncherMaterializesButNeverRegisters() throws {
    let launcher = AgentLauncher()
    launcher.registersPlugin = false

    launcher.syncAgentPluginOnLaunch()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))

    let materialized = try XCTUnwrap(AgentPluginInstaller.stablePluginDir)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: materialized.appendingPathComponent("install.sh").path)
    )
    XCTAssertEqual(runCount, 0, "中身の指紋が記録と違っても登録しない")
    XCTAssertNil(AgentPluginInstaller.registeredDigest)

    AppStatePersistence.save(AppStateFile())
    let model = AppShellModel(statusModel: StatusRowModel(), content: NSView())
    launcher.appModel = model
    launcher.showOnboardingIfNeeded()
    XCTAssertEqual(model.overlay, .none, "登録のためのオンボーディングを出さない")
    XCTAssertNil(model.onboarding)
  }
}
