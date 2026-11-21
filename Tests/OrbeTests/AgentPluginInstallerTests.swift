import OrbeTestSupport
import XCTest

@testable import Orbe

/// パッケージのプラグイン名の導出規則（`AgentPluginInstaller.pluginName(in:)`）、中身の指紋、
/// `run` の完了順序を固定する。
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

  // MARK: - 中身の指紋

  /// 指紋は「CLI に登録するもの」が変われば変わり、変わらなければ同じ。起動時の入れ直しはこれだけで
  /// 決まるので、変化を見逃すと codex / agy に古いコピーが残り、変化の無い起動で拾うと毎回入れ直す。
  func testDigestTracksContentsPathsAndHiddenFiles() throws {
    try write("codex/orbe-agent-dev/.codex-plugin/plugin.json", "{}")
    try write("plugins/orbe-agent-dev/channel", "dev.orbe.app.dev\n")
    let base = try XCTUnwrap(AgentPluginInstaller.digest(of: pkg))

    try write("plugins/orbe-agent-dev/channel", "dev.orbe.app\n")
    XCTAssertNotEqual(AgentPluginInstaller.digest(of: pkg), base, "刻印の中身")
    try write("plugins/orbe-agent-dev/channel", "dev.orbe.app.dev\n")
    XCTAssertEqual(AgentPluginInstaller.digest(of: pkg), base)

    try write("codex/orbe-agent-dev/.codex-plugin/plugin.json", #"{"mcpServers":{}}"#)
    XCTAssertNotEqual(AgentPluginInstaller.digest(of: pkg), base, "隠しディレクトリの中の定義")
    try write("codex/orbe-agent-dev/.codex-plugin/plugin.json", "{}")

    try FileManager.default.moveItem(
      at: pkg.appendingPathComponent("plugins/orbe-agent-dev"),
      to: pkg.appendingPathComponent("plugins/orbe-agent"))
    XCTAssertNotEqual(AgentPluginInstaller.digest(of: pkg), base, "名前（ディレクトリ名）")
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
  private func runInstaller(script: String?, shellPATH: String = "/usr/bin:/bin") throws -> [String]
  {
    if let script {
      try script.write(
        to: pkg.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
    }
    var log: [String] = []
    let done = expectation(description: "install.sh complete")
    AgentPluginInstaller.run(
      pluginDir: pkg, pluginName: "orbe-agent", shellPATH: shellPATH,
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

  // MARK: - 同梱の install.sh

  private static let bundledInstallScript = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("app/agent-plugin/install.sh")

  /// 偽の claude だけを PATH に置いて同梱の install.sh を実行する。偽の claude は受けた引数を 1 行ずつ残し、`plugin list` には
  /// `list` を出して `listStatus` で終わる。返すのは届いた Event と、claude が受けた呼び出しの列。
  private func runBundledInstaller(claudeList list: String, listStatus: Int32) throws -> (
    log: [String], calls: [String]
  ) {
    let bin = pkg.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let calls = pkg.appendingPathComponent("claude-calls.log")
    let listed = pkg.appendingPathComponent("claude-list.txt")
    try Data(list.utf8).write(to: listed)
    let claude = bin.appendingPathComponent("claude")
    try """
    #!/bin/sh
    echo "$*" >> "\(calls.path)"
    if [ "$1 $2" = "plugin list" ]; then cat "\(listed.path)"; exit \(listStatus); fi
    exit 0
    """.write(to: claude, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    let log = try runInstaller(
      script: String(contentsOf: Self.bundledInstallScript, encoding: .utf8),
      shellPATH: "\(bin.path):/usr/bin:/bin")
    let called = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
      .split(separator: "\n").map(String.init)
    return (log, called)
  }

  /// claude の一覧が失敗し、このプラグインの行も出さなかったときは導入を試みず失敗にする。claude の plugin install は無効にした
  /// プラグインを有効へ戻すので、導入済みかどうか分からないまま導入すると、利用者が無効にした設定を黙って覆す。
  func testUnreadableClaudeListIsAnErrorWithoutInstalling() throws {
    let run = try runBundledInstaller(claudeList: "", listStatus: 1)
    XCTAssertTrue(run.log.contains("ng claude"), "\(run.log)")
    XCTAssertFalse(run.calls.contains { $0.hasPrefix("plugin install") }, "\(run.calls)")
  }

  /// このプラグインの行は無効にしても一覧に残るので、一覧が失敗しても行があれば導入済みとして何もしない。
  func testClaudeListShowingThePluginIsUnchangedWhateverItsStatus() throws {
    let run = try runBundledInstaller(
      claudeList: "  ❯ orbe-agent@orbe-agent\n    Status: ✘ disabled\n", listStatus: 1)
    XCTAssertTrue(run.log.contains("ok claude"), "\(run.log)")
    XCTAssertFalse(run.calls.contains { $0.hasPrefix("plugin install") }, "\(run.calls)")
  }

  /// 一覧が最後まで出てこのプラグインの行が無ければ、未導入なので導入する。
  func testCompleteClaudeListWithoutThePluginInstallsIt() throws {
    let run = try runBundledInstaller(claudeList: "No plugins installed.\n", listStatus: 0)
    XCTAssertTrue(run.log.contains("ok claude"), "\(run.log)")
    XCTAssertTrue(run.calls.contains("plugin install orbe-agent@orbe-agent"), "\(run.calls)")
  }
}
