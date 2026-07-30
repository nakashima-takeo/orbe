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

  /// 隠しファイルは数に入れない。`build-app.sh` はワーキングツリーをそのままコピーするので、
  /// Finder が置いた `.DS_Store` がパッケージに載りうる。数えると名前が引けなくなり導入が丸ごと死ぬ。
  func testHiddenFilesAreIgnored() throws {
    try makePluginsDir(subdirectories: ["orbe-agent-dev"])
    try Data().write(to: pkg.appendingPathComponent("plugins/.DS_Store"))
    XCTAssertEqual(AgentPluginInstaller.pluginName(in: pkg), "orbe-agent-dev")
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
      pluginDir: pkg, pluginName: "orbe-agent", shellPATH: nil,
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
