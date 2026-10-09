import OrbeTestSupport
import XCTest

@testable import Orbe

/// パッケージのプラグイン名の導出規則（`AgentPluginInstaller.pluginName(in:)`）、中身の指紋と登録の
/// 記録、`run` の完了順序を固定する。
/// 名前はビルド時にチャネルから導出されるため Swift には焼けず、`plugins/` 直下の唯一の
/// サブディレクトリ名として読む。この 1 つの名前を marketplace 登録と channel の置き場所が
/// 共有するので、曖昧なパッケージでは nil を返す（誤った名前で登録しない）。
final class AgentPluginInstallerTests: OrbeTestCase {
  private var pkg: URL!

  override func setUpWithError() throws {
    pkg = TestScratch.caseDir
      .appendingPathComponent("AgentPluginInstallerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
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

  /// `plugins/` が無い・空なら名前は決まらない。
  func testMissingOrEmptyPluginsDirectoryIsNil() throws {
    XCTAssertNil(AgentPluginInstaller.pluginName(in: pkg), "plugins/ が無い")
    try makePluginsDir()
    XCTAssertNil(AgentPluginInstaller.pluginName(in: pkg), "plugins/ が空")
  }

  /// 2 つ在ればどちらが自分の名前か決まらない。
  func testMultipleSubdirectoriesAreNil() throws {
    try makePluginsDir(subdirectories: ["orbe-agent", "orbe-agent-dev"])
    XCTAssertNil(AgentPluginInstaller.pluginName(in: pkg))
  }

  /// ディレクトリでない唯一のエントリはプラグインではない。
  func testSoleFileIsNil() throws {
    try makePluginsDir()
    try Data().write(to: pkg.appendingPathComponent("plugins/README"))
    XCTAssertNil(AgentPluginInstaller.pluginName(in: pkg))
  }

  /// 隠しファイルは数に入れない。`build-app.sh` はワーキングツリーをそのままコピーするので、
  /// Finder が置いた `.DS_Store` がパッケージに載りうる。数えると名前が引けなくなり導入が丸ごと死ぬ。
  func testHiddenFilesAreIgnored() throws {
    try makePluginsDir(subdirectories: ["orbe-agent-dev"])
    try Data().write(to: pkg.appendingPathComponent("plugins/.DS_Store"))
    XCTAssertEqual(AgentPluginInstaller.pluginName(in: pkg), "orbe-agent-dev")
  }

  // MARK: - 中身の指紋と登録の記録

  /// 指紋は「CLI に登録するもの」が変われば変わり、変わらなければ同じ。起動時の入れ直しはこれだけで
  /// 決まるので、変化を見逃すと codex / agy に古いコピーが残り、変化の無い起動で拾うと毎回入れ直す。
  func testDigestTracksContentsPathsAndHiddenFilesButNotLocation() throws {
    try write("plugins/orbe-agent-dev/.codex-plugin/plugin.json", "{}")
    try write("plugins/orbe-agent-dev/channel", "dev.orbe.app.dev\n")
    let base = try XCTUnwrap(AgentPluginInstaller.digest(of: pkg))

    let copy = pkg.deletingLastPathComponent().appendingPathComponent("copy-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: pkg, to: copy)
    XCTAssertEqual(AgentPluginInstaller.digest(of: copy), base, "置き場所が違っても中身が同じなら同じ")

    try write("plugins/orbe-agent-dev/channel", "dev.orbe.app\n")
    XCTAssertNotEqual(AgentPluginInstaller.digest(of: pkg), base, "刻印の中身")
    try write("plugins/orbe-agent-dev/channel", "dev.orbe.app.dev\n")
    XCTAssertEqual(AgentPluginInstaller.digest(of: pkg), base)

    try write("plugins/orbe-agent-dev/.codex-plugin/plugin.json", #"{"mcpServers":{}}"#)
    XCTAssertNotEqual(AgentPluginInstaller.digest(of: pkg), base, "隠しディレクトリの中の定義")
    try write("plugins/orbe-agent-dev/.codex-plugin/plugin.json", "{}")

    try FileManager.default.moveItem(
      at: pkg.appendingPathComponent("plugins/orbe-agent-dev"),
      to: pkg.appendingPathComponent("plugins/orbe-agent"))
    XCTAssertNotEqual(AgentPluginInstaller.digest(of: pkg), base, "名前（ディレクトリ名）")
  }

  func testDigestOfEmptyOrMissingPackageIsNil() throws {
    XCTAssertNil(AgentPluginInstaller.digest(of: pkg.appendingPathComponent("missing")))
    XCTAssertNil(AgentPluginInstaller.digest(of: pkg), "ファイルが 1 つも無い")
  }

  /// 記録は実体化先の外に置く。中に置くと、毎起動の実体化（丸ごと差し替え）が記録を消し、
  /// 毎回入れ直しになる。
  func testRecordedDigestSurvivesMaterialization() throws {
    let resources = try XCTUnwrap(BundledResources.root)
    let bundled = resources.appendingPathComponent("agent-plugin")
    try FileManager.default.createDirectory(
      at: bundled.appendingPathComponent("plugins/orbe-agent-dev"),
      withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: bundled.appendingPathComponent("install.sh").path, contents: Data(),
      attributes: [.posixPermissions: 0o755])

    let dir = try XCTUnwrap(AgentPluginInstaller.materializeStablePlugin())
    XCTAssertNil(AgentPluginInstaller.registeredDigest, "記録が無い＝既存の利用者は一度入れ直される")
    let digest = try XCTUnwrap(AgentPluginInstaller.digest(of: dir))
    AgentPluginInstaller.recordRegistered(digest: digest)

    let again = try XCTUnwrap(AgentPluginInstaller.materializeStablePlugin())
    XCTAssertEqual(AgentPluginInstaller.registeredDigest, digest)
    XCTAssertEqual(AgentPluginInstaller.digest(of: again), digest, "同じ同梱物の実体化は同じ指紋")
  }

  private func write(_ rel: String, _ text: String) throws {
    let url = pkg.appendingPathComponent(rel)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  // MARK: - run の完了順序

  /// `pkg` を install.sh の置き場にして `run` を回し、届いた Event と完了を届いた順に記録する。
  /// 完了は "complete" として同じ列に積むので、取りこぼしと順序を 1 本の列で検証できる。
  private func runInstaller(script: String?) throws -> [String] {
    if let script {
      try script.write(
        to: pkg.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
    }
    var log: [String] = []
    let done = expectation(description: "install.sh complete")
    AgentPluginInstaller.run(
      pluginDir: pkg, pluginName: "orbe-agent", shellPATH: "/usr/bin:/bin",
      onEvent: { event in
        switch event {
        case .start(let cli): log.append("start \(cli)")
        case .done(let cli, let ok): log.append("\(ok ? "ok" : "ng") \(cli)")
        case .skip(let cli): log.append("skip \(cli)")
        }
      },
      onComplete: {
        log.append("complete")
        done.fulfill()
      })
    wait(for: [done], timeout: 30)
    return log
  }

  /// stdout に出した行が 1 つ残らず `onEvent` に届いてから `onComplete` が来る。
  /// 呼び出し側は完了時点で失敗の有無を判定するので、最後の行（＝最後の CLI の成否）を
  /// 落とすと失敗を見逃す。パイプのバッファを超える量を一気に吐かせ、読み取りのチャンク境界
  /// （行の途中で切れる）を跨いで 1 行も欠けないことを見る。
  func testAllLinesArriveBeforeCompletion() throws {
    let count = 5000
    let log = try runInstaller(
      script: """
        i=1
        while [ $i -le \(count) ]; do
          echo "installed cli$i"
          i=$((i + 1))
        done
        """)
    XCTAssertEqual(log.count, count + 1)
    XCTAssertEqual(log.first, "ok cli1")
    XCTAssertEqual(log[count - 1], "ok cli\(count)")
    XCTAssertEqual(log.last, "complete")
  }

  /// 完了の起点はプロセスの終了ではなく stdout の読み切り。プロセスが先に終わっても、
  /// stdout を持ったままの子が出した行は届き、その後で完了が来る（終了で打ち切ると落ちる行）。
  func testLineWrittenAfterExitStillArrivesBeforeCompletion() throws {
    let log = try runInstaller(
      script: """
        echo "start agy"
        (sleep 0.3; echo "error agy") &
        """)
    XCTAssertEqual(log, ["start agy", "ng agy", "complete"])
  }

  /// 改行で終わらない最後の行も 1 行として届く（EOF が行の終わり）。
  func testTrailingLineWithoutNewlineArrives() throws {
    let log = try runInstaller(
      script: """
        echo "start agy"
        printf "error agy"
        """)
    XCTAssertEqual(log, ["start agy", "ng agy", "complete"])
  }

  /// 1 行も出さずに終わっても完了は届く（呼び出し側の「導入中」が残らない）。
  func testMissingScriptStillCompletes() throws {
    XCTAssertEqual(try runInstaller(script: nil), ["complete"])
  }
}
