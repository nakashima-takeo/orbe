import XCTest

@testable import Orbe

/// パッケージのプラグイン名の導出規則（`AgentPluginInstaller.pluginName(in:)`）を固定する。
/// 名前はビルド時にチャネルから導出されるため Swift には焼けず、`plugins/` 直下の唯一の
/// サブディレクトリ名として読む。この 1 つの名前を marketplace 登録・登録済みの記録・
/// channel の置き場所が共有するので、曖昧なパッケージでは nil を返す（誤った名前で登録しない）。
final class AgentPluginInstallerTests: XCTestCase {
  private var pkg: URL!

  override func setUpWithError() throws {
    pkg = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("AgentPluginInstallerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: pkg)
  }

  private func makePluginsDir(subdirectories: [String] = []) throws {
    let plugins = pkg.appendingPathComponent("plugins")
    try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
    for name in subdirectories {
      try FileManager.default.createDirectory(
        at: plugins.appendingPathComponent(name), withIntermediateDirectories: true)
    }
  }

  func testSoleSubdirectoryIsTheName() throws {
    try makePluginsDir(subdirectories: ["orbe-agent-dev"])
    XCTAssertEqual(AgentPluginInstaller.pluginName(in: pkg), "orbe-agent-dev")
  }

  func testEmptyPluginsDirectoryIsNil() throws {
    try makePluginsDir()
    XCTAssertNil(AgentPluginInstaller.pluginName(in: pkg))
  }

  /// 2 つ在ればどちらが自分の名前か決まらない。
  func testMultipleSubdirectoriesAreNil() throws {
    try makePluginsDir(subdirectories: ["orbe-agent", "orbe-agent-dev"])
    XCTAssertNil(AgentPluginInstaller.pluginName(in: pkg))
  }

  func testMissingPluginsDirectoryIsNil() {
    XCTAssertNil(AgentPluginInstaller.pluginName(in: pkg))
  }

  /// ディレクトリでない唯一のエントリはプラグインではない。
  func testSoleFileIsNil() throws {
    try makePluginsDir()
    try Data().write(to: pkg.appendingPathComponent("plugins/README"))
    XCTAssertNil(AgentPluginInstaller.pluginName(in: pkg))
  }
}
