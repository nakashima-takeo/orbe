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
    try write("codex/orbe-agent-dev/.codex-plugin/plugin.json", "{}")
    AppStatePersistence.save(AppStateFile(agentPluginsInstalled: true))
  }

  private func write(_ rel: String, _ text: String) throws {
    let url = bundled.appendingPathComponent(rel)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private var registeredDigest: String? { AppStatePersistence.load()?.registeredAgentPluginDigest }

  private var runCount: Int {
    ((try? String(contentsOf: runs, encoding: .utf8)) ?? "").split(separator: "\n").count
  }

  func testInstallerRunsOnlyOnLaunchesWhosePackageContentsChanged() throws {
    let launcher = AgentLauncher()
    launcher.registersPlugin = true

    launcher.syncAgentPluginOnLaunch()
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: try XCTUnwrap(AgentPluginInstaller.stablePluginDir).path),
      "登録する起動は、呼び出しの中で実体化する。"
        + "これが待たずに成り立たなくなれば、testIsolatedLauncherNeitherMaterializesNorRegisters の確かめる時点も成り立たない")
    pumpMain(until: { registeredDigest != nil }, "登録の記録が無い起動で入れ直す")
    let first = registeredDigest

    launcher.syncAgentPluginOnLaunch()  // 同じ中身のまま起動し直す

    try write("plugins/orbe-agent-dev/mcp_config.json", #"{"mcpServers":{}}"#)
    launcher.syncAgentPluginOnLaunch()
    pumpMain(until: { registeredDigest != first }, "中身の変わった起動で入れ直す")

    XCTAssertEqual(runCount, 2, "同じ中身の起動では走らない")
  }

  /// 隔離起動（`ORBE_STATE_DIR` を持つ Orbe）は既定で、実体化も CLI への登録（install.sh）も、そのための
  /// オンボーディングもしない。
  ///
  /// 壊れると何が起きるか: 検証用に起こした Orbe が利用者の claude / codex / agy の登録先を自分の一時フォルダへ向け替え、
  /// codex / agy のコピーを検証中の中身で上書きする。片付けた後には利用者の agent から状態追跡と MCP が消える。
  ///
  /// 実体化しないことは、呼び出しの直後に確かめる（実体化は呼び出しの中で同期に済む）。登録しないことは、1 秒のあいだ
  /// 見張って確かめる。登録は `install.sh` の子プロセスで走り、起動したかをテストから確認する手段が無い（導入中のプロセスは
  /// `AgentLauncher` の private な状態）。本番に、登録が始まるまでの遅延の定数は無い。1 秒は、登録する起動で偽の
  /// `install.sh` が起動から記録を書くまでの時間（手元で約 0.01 秒）より十分に長くとった。
  func testIsolatedLauncherNeitherMaterializesNorRegisters() throws {
    let launcher = AgentLauncher()
    XCTAssertFalse(launcher.registersPlugin, "ORBE_STATE_DIR を持つ Orbe は既定で登録しない")

    launcher.syncAgentPluginOnLaunch()

    let place = try XCTUnwrap(AgentPluginInstaller.stablePluginDir)
    XCTAssertFalse(FileManager.default.fileExists(atPath: place.path), "実体化しない")
    XCTAssertTrue(
      holds(for: 1) { runCount == 0 }, "中身の指紋が記録と違っても登録しない（install.sh が走った）")
    XCTAssertNil(registeredDigest)

    AppStatePersistence.save(AppStateFile())
    let model = AppShellModel(statusModel: StatusRowModel(), content: NSView())
    launcher.appModel = model
    launcher.showOnboardingIfNeeded()
    XCTAssertEqual(model.overlay, .none, "登録のためのオンボーディングを出さない")
    XCTAssertNil(model.onboarding)
  }
}
