import OrbeTestSupport
import XCTest

@testable import Orbe

/// 同梱の install.sh の、各 CLI へ導入するかを決める規則と、各コマンドに掛ける時限を、偽の CLI を相手に固定する。
///
/// 壊れると何が起きるか。claude の一覧が読めないまま導入して、利用者が無効にしたプラグインを有効へ戻す。CLI が固まると
/// 時限で打ち切れず、起動時の導入が止まったままになる。打ち切った一覧の CLI が 0 で終わったのを成功と読み、未導入と見て導入する。
/// codex・agy を入れ直さなくなり、中身の更新が届かない。
extension AgentPluginInstallerTests {
  private static let bundledInstallScript = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("app/agent-plugin/install.sh")

  /// 時限のテストで、確かめる 1 つのコマンドに最初に渡す時限（やり直すたびに倍にする）と、ほかの 2 つのコマンドに渡す時限。
  /// 確かめるコマンドは `hang` で止まる。確かめる時限が別のコマンドに掛かっていれば、止まったコマンドは長い時限か `sleep` の
  /// 終わりまで止まり続け、`runInstaller` の待ちの上限で落ちる。
  private static let cut: TimeInterval = 0.3
  private static let long: TimeInterval = 120
  private static let hang = "exec sleep 60"

  /// 偽の claude が受ける、時限を掛けるコマンド。
  private enum ClaudeCommand {
    case register, list, install

    /// 偽の claude が残す呼び出しの記録のうち、このコマンドを表す先頭の文字列。
    var call: String {
      switch self {
      case .register: "plugin marketplace add"
      case .list: "plugin list"
      case .install: "plugin install"
      }
    }
  }

  /// `stopped` だけを `hang` で止め、その時限だけを短くして、ほかの 2 つを `long` にして実行する。時限は、偽の claude が
  /// 呼び出しを残す前に来ることが在る（負荷で起動が遅れた回）。その回は、止めたコマンドが呼ばれたことを確かめられないので、
  /// 呼び出しの記録を消し、時限を倍にしてやり直す（実行は 5 回まで）。返すのは、呼び出しを残せた回の結果か、5 回めの結果。
  private func runCuttingClaude(_ stopped: ClaudeCommand) throws -> (
    log: [String], calls: [String]
  ) {
    var limit = Self.cut
    var run: (log: [String], calls: [String]) = ([], [])
    for _ in 0..<5 {
      try? FileManager.default.removeItem(at: pkg.appendingPathComponent("claude-calls.log"))
      run = try runBundledInstaller(
        claudeList: "No plugins installed.\n",
        registerPrelude: stopped == .register ? Self.hang : "",
        listPrelude: stopped == .list ? Self.hang : "",
        installPrelude: stopped == .install ? Self.hang : "",
        limits: .init(
          register: stopped == .register ? limit : Self.long,
          list: stopped == .list ? limit : Self.long,
          install: stopped == .install ? limit : Self.long))
      if run.calls.contains(where: { $0.hasPrefix(stopped.call) }) { break }
      limit *= 2
    }
    return run
  }

  /// 偽の CLI を、同梱の install.sh を実行するときの PATH に置く。偽の CLI は受けた引数を 1 行ずつ残してから `body` を実行する。
  private func placeFakeCLI(_ name: String, body: String) throws {
    let bin = pkg.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let cli = bin.appendingPathComponent(name)
    try """
    #!/bin/sh
    echo "$*" >> "\(pkg.appendingPathComponent("\(name)-calls.log").path)"
    \(body)
    """.write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
  }

  /// 偽の CLI が受けた呼び出しの列。
  private func calls(of name: String) -> [String] {
    ((try? String(contentsOf: pkg.appendingPathComponent("\(name)-calls.log"), encoding: .utf8))
      ?? "").split(separator: "\n").map(String.init)
  }

  /// `placeFakeCLI` で置いた偽の CLI だけが PATH に在る状態で、同梱の install.sh を `runInstaller` で実行する。
  private func runBundledScript(
    limits: AgentPluginInstaller.TimeLimits = .init(),
    whileRunning: (Process) throws -> Void = { _ in }
  ) throws -> [String] {
    try runInstaller(
      script: String(contentsOf: Self.bundledInstallScript, encoding: .utf8),
      shellPATH: "\(pkg.appendingPathComponent("bin").path):/usr/bin:/bin", limits: limits,
      whileRunning: whileRunning)
  }

  /// 偽の claude だけを置いて同梱の install.sh を実行する。偽の claude は、登録（`plugin marketplace add`）・一覧
  /// （`plugin list`）・導入（`plugin install`）では、それぞれの prelude を実行する。その後、一覧は `list` を出力して
  /// 終了コード `listStatus` で終了し、ほかは終了コード 0 で終了する。返すのは届いた Event と、claude が受けた呼び出しの列。
  private func runBundledInstaller(
    claudeList list: String = "", listStatus: Int32 = 0, registerPrelude: String = "",
    listPrelude: String = "", installPrelude: String = "",
    limits: AgentPluginInstaller.TimeLimits = .init(),
    whileRunning: (Process) throws -> Void = { _ in }
  ) throws -> (log: [String], calls: [String]) {
    let listed = pkg.appendingPathComponent("claude-list.txt")
    try Data(list.utf8).write(to: listed)
    try placeFakeCLI(
      "claude",
      body: """
        case "$1 $2" in
        "plugin marketplace")
        \(registerPrelude)
        ;;
        "plugin list")
        \(listPrelude)
        cat "\(listed.path)"; exit \(listStatus)
        ;;
        "plugin install")
        \(installPrelude)
        ;;
        esac
        exit 0
        """)
    let log = try runBundledScript(limits: limits, whileRunning: whileRunning)
    return (log, calls(of: "claude"))
  }

  /// claude の一覧が失敗し、このプラグインの行も出さなかったときは導入を試みず失敗にする。claude の plugin install は無効にした
  /// プラグインを有効へ戻すので、導入済みかどうか分からないまま導入すると、利用者が無効にした設定を黙って覆す。
  func testUnreadableClaudeListIsAnErrorWithoutInstalling() throws {
    let run = try runBundledInstaller(claudeList: "", listStatus: 1)
    XCTAssertTrue(run.log.contains("ng claude"), "\(run.log)")
    XCTAssertFalse(run.calls.contains { $0.hasPrefix("plugin install") }, "\(run.calls)")
  }

  /// このプラグインの行は無効にしても一覧に残るので、一覧が失敗しても行があれば導入済みとして何もしない。
  func testClaudeListShowingThePluginIsUnchangedEvenWhenTheListFails() throws {
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

  /// 時限を過ぎても終わらない登録は打ち切り、登録の結果を見ずに一覧と導入へ進む。打ち切りが効かなければ起動時の導入が止まったままになる。
  func testClaudeRegisterPastItsTimeLimitIsCutOffAndTheInstallGoesOn() throws {
    let run = try runCuttingClaude(.register)
    XCTAssertTrue(run.calls.contains { $0.hasPrefix("plugin marketplace add") }, "\(run.calls)")
    XCTAssertTrue(run.log.contains("ok claude"), "\(run.log)")
    XCTAssertTrue(run.calls.contains("plugin install orbe-agent@orbe-agent"), "\(run.calls)")
  }

  /// 時限を過ぎても終わらない一覧は打ち切って失敗として扱い、導入を試みない。打ち切りが効かなければ起動時の導入が止まったままになる。
  func testClaudeListPastItsTimeLimitIsCutOffAndAnErrorWithoutInstalling() throws {
    let run = try runCuttingClaude(.list)
    XCTAssertTrue(run.calls.contains("plugin list"), "\(run.calls)")
    XCTAssertTrue(run.log.contains("ng claude"), "\(run.log)")
    XCTAssertFalse(run.calls.contains { $0.hasPrefix("plugin install") }, "\(run.calls)")
  }

  /// 時限を過ぎても終わらない導入は打ち切って失敗にする。打ち切りが効かなければ起動時の導入が止まったままになる。
  func testClaudeInstallPastItsTimeLimitIsCutOffAndAnError() throws {
    let run = try runCuttingClaude(.install)
    XCTAssertTrue(run.calls.contains("plugin install orbe-agent@orbe-agent"), "\(run.calls)")
    XCTAssertTrue(run.log.contains("ng claude"), "\(run.log)")
  }

  /// 打ち切った一覧は、CLI が終了の要求（SIGTERM）を受けて 0 で終わっても失敗にする（agy は SIGTERM を受けて 0 で終わる
  /// ことがある）。打ち切った一覧を成功と読めば、未導入と見て導入する。偽の claude は、SIGTERM に 0 で終わる trap を置いた後に、
  /// 時限を数える perl（自分の親）の pid を印のファイル（`tmo.pid`）に書いて止まる。その pid へ SIGALRM を送って、時限の到来を起こす。
  /// 時限はどれも長くするので、打ち切りはテストが送った SIGALRM でしか起きない。
  func testClaudeListCutOffIsAnErrorEvenWhenTheCLIExitsZero() throws {
    let pidMark = pkg.appendingPathComponent("tmo.pid")
    let trapped = pkg.appendingPathComponent("trapped")
    let run = try runBundledInstaller(
      listPrelude: """
        trap ': > "\(trapped.path)"; kill $! 2>/dev/null; exit 0' TERM
        sleep 60 &
        echo "$PPID" > "\(pidMark.path).tmp" && mv "\(pidMark.path).tmp" "\(pidMark.path)"
        wait
        """,
      limits: .init(register: Self.long, list: Self.long, install: Self.long),
      whileRunning: { _ in
        var timer: pid_t?
        pumpMain(
          until: {
            guard let text = try? String(contentsOf: pidMark, encoding: .utf8),
              text.hasSuffix("\n")
            else { return false }
            timer = pid_t(text.dropLast())
            return true
          }, "時限を数える perl の pid")
        kill(try XCTUnwrap(timer, "tmo.pid の中身が pid でない"), SIGALRM)
      })
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: trapped.path), "一覧が SIGTERM を受けて 0 で終わっていない")
    XCTAssertTrue(run.log.contains("ng claude"), "\(run.log)")
    XCTAssertFalse(run.calls.contains { $0.hasPrefix("plugin install") }, "\(run.calls)")
  }

  // MARK: - codex と agy の導入

  /// codex は、登録の後に一覧を読み、利用者が無効にしていなければ `plugin add` で入れ直す（キャッシュのコピーを今の中身へ
  /// 置き換える）。入れ直さなければ、中身の更新が codex に届かない。
  func testCodexNotDisabledIsReinstalled() throws {
    try placeFakeCLI(
      "codex",
      body: """
        if [ "$1 $2" = "plugin list" ]; then
          echo '{"installed":[{"pluginId":"orbe-agent@orbe-agent","enabled":true}]}'
        fi
        exit 0
        """)
    let log = try runBundledScript()
    XCTAssertTrue(log.contains("ok codex"), "\(log)")
    XCTAssertEqual(
      calls(of: "codex"),
      [
        "plugin marketplace add \(pkg.path)", "plugin list --json --marketplace orbe-agent",
        "plugin add orbe-agent@orbe-agent",
      ])
  }

  /// agy は、プラグイン本体のディレクトリを `plugin install` で入れ直す（ステージ先を今の中身へ置き換える）。入れ直さなければ、
  /// 中身の更新が agy に届かない。
  func testAgyIsReinstalledFromThePluginDirectory() throws {
    try placeFakeCLI("agy", body: "exit 0")
    let log = try runBundledScript()
    XCTAssertTrue(log.contains("ok agy"), "\(log)")
    XCTAssertEqual(calls(of: "agy"), ["plugin install \(pkg.path)/plugins/orbe-agent"])
  }
}
