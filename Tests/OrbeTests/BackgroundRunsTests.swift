import OrbeTestSupport
import XCTest

@testable import Orbe

/// 実行の係——種類ごとの別々の枠で同時数を絞り、溢れた分は来た順に待つ、止める手・全停止、子の環境と作業ディレクトリ、
/// claude を契約どおりの引数と標準入力の依頼文で走らせて最終応答を受け取る、走らせられないものは理由付きで返す。
///
/// 壊れると何が起きるか。再起動の直後に claude が何本も立ち上がる。軽い確認のコマンドが重い agent の後ろで待たされる。
/// Orbe を終えた後に子が残る。claude が利用者の設定や MCP サーバーを読んで、指定していないツールを使う。
final class BackgroundRunsTests: OrbeTestCase {
  private var bin: URL!

  override func setUpWithError() throws {
    bin = TestScratch.caseDir.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  }

  private func runs(agents: Int = 2, commands: Int = 4, withBin: Bool = true) -> BackgroundRuns {
    let path = withBin ? "\(bin.path):/usr/bin:/bin" : "/usr/bin:/bin"
    return BackgroundRuns(slots: [.agent: agents, .command: commands]) { path }
  }

  /// 偽の claude を置く。受けた引数（NUL 区切り）と標準入力を隣へ書き、`body` を実行する。
  private func placeClaude(_ body: String) throws {
    let script = """
      #!/bin/sh
      dir=$(dirname "$0")
      for a in "$@"; do printf '%s\\0' "$a"; done > "$dir/args"
      cat > "$dir/stdin"
      \(body)
      """
    let url = bin.appendingPathComponent("claude")
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  private func receivedArguments() throws -> [String] {
    let data = try Data(contentsOf: bin.appendingPathComponent("args"))
    return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
      String(bytes: $0, encoding: .utf8) ?? ""
    }
  }

  private func run(
    _ runs: BackgroundRuns, _ job: BackgroundJob, timeout: TimeInterval = 20
  ) throws -> BackgroundRunResult {
    var result: BackgroundRunResult?
    let done = expectation(description: "run")
    _ = runs.run(job) {
      XCTAssertTrue(Thread.isMainThread, "結果は main で届く（番人は main だけで動く）")
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: timeout)
    return try XCTUnwrap(result)
  }

  private func command(_ script: String, in directory: String? = nil) -> BackgroundJob {
    .command(BackgroundCommand(script: script, directory: directory))
  }

  private func agent(_ cli: String = "claude", tools: [String] = []) -> BackgroundJob {
    .agent(BackgroundAgentCall(cli: cli, model: "haiku", tools: tools, prompt: "判定して"))
  }

  private func stdout(_ result: BackgroundRunResult) -> String {
    guard case .command(let stdout, _) = result.output else { return "" }
    return String(bytes: stdout.data, encoding: .utf8) ?? ""
  }

  private func reply(_ result: BackgroundRunResult) -> BackgroundAgentReply? {
    guard case .agent(let reply, _) = result.output else { return nil }
    return reply
  }

  // MARK: - コマンド

  func testCommandRunsInItsDirectoryWithChildPATH() throws {
    let dir = TestScratch.caseDir.path
    let physical = try XCTUnwrap(realpath(dir, nil).map { String(cString: $0) })

    let result = try run(runs(), command(#"pwd -P; printf %s "$PATH""#, in: dir))

    XCTAssertEqual(result.ending, .exited(0))
    XCTAssertEqual(result.commandLine, #"pwd -P; printf %s "$PATH""#)
    XCTAssertEqual(stdout(result), "\(physical)\n\(bin.path):/usr/bin:/bin")
  }

  func testCommandDefaultsToHome() throws {
    let result = try run(runs(), command("pwd"))

    XCTAssertEqual(stdout(result), NSHomeDirectory() + "\n")
  }

  func testMissingDirectoryIsNotStarted() throws {
    let missing = TestScratch.caseDir.appendingPathComponent("gone").path

    let result = try run(runs(), command("true", in: missing))

    XCTAssertEqual(result.ending, .notStarted(.directoryMissing(missing)))
    XCTAssertEqual(result.output, .none)
  }

  func testInvalidJobIsNotStarted() throws {
    XCTAssertEqual(
      try run(runs(), command(" ")).ending, .notStarted(.invalid(.emptyCommand)))
  }

  // MARK: - 枠

  /// 枠から溢れた分は、走っている回が終わるまで始まらない。
  func testCommandsBeyondTheSlotsWait() throws {
    let runs = runs(commands: 2)
    var results: [BackgroundRunResult] = []
    let done = expectation(description: "all")
    done.expectedFulfillmentCount = 3
    for _ in 0..<3 {
      _ = runs.run(command("sleep 0.5")) {
        results.append($0)
        done.fulfill()
      }
    }
    wait(for: [done], timeout: 20)

    let ordered = results.sorted { $0.startedAt < $1.startedAt }
    XCTAssertGreaterThanOrEqual(
      ordered[2].startedAt, min(ordered[0].endedAt, ordered[1].endedAt), "3 本目は枠が空くまで待つ")
  }

  /// agent とコマンドの枠は別々。agent が枠を塞いでいても、コマンドは待たされない。
  func testCommandDoesNotWaitBehindAgents() throws {
    try placeClaude("sleep 30")
    let runs = runs(agents: 1, commands: 1)
    let agentHandle = runs.run(agent()) { _ in }

    let result = try run(runs, command("echo fast"), timeout: 10)
    agentHandle.stop()

    XCTAssertEqual(stdout(result), "fast\n")
  }

  // MARK: - 止める

  func testStoppingAWaitingRunReturnsStoppedWithoutStarting() throws {
    let runs = runs(commands: 1)
    let first = runs.run(command("sleep 30")) { _ in }
    var stopped: BackgroundRunResult?
    let done = expectation(description: "stopped")
    let second = runs.run(command("echo second")) {
      stopped = $0
      done.fulfill()
    }

    second.stop()
    wait(for: [done], timeout: 5)
    first.stop()

    XCTAssertEqual(stopped?.ending, .stopped)
    XCTAssertEqual(stopped?.output, BackgroundOutput.none)
  }

  func testStoppingARunningRunReturnsStopped() throws {
    let runs = runs()
    var result: BackgroundRunResult?
    let done = expectation(description: "stopped")
    let handle = runs.run(command("sleep 30")) {
      result = $0
      done.fulfill()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { handle.stop() }

    wait(for: [done], timeout: 10)

    XCTAssertEqual(result?.ending, .stopped)
  }

  /// 全停止は走っている子のグループを止めて回収してから返り、順番待ちの分は捨てる。
  func testStopAllStopsRunningGroupsAndDropsWaiting() throws {
    let runs = runs(commands: 1)
    let pidFile = TestScratch.caseDir.appendingPathComponent("pid").path
    _ = runs.run(command("sleep 30 & echo $! > \(pidFile); wait")) { _ in }
    var waitingCompleted = false
    _ = runs.run(command("echo never")) { _ in waitingCompleted = true }
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: pidFile), Date() < deadline { usleep(20_000) }
    let pid = try XCTUnwrap(
      pid_t(
        try String(contentsOfFile: pidFile, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)))

    let started = Date()
    runs.stopAll()
    let elapsed = Date().timeIntervalSince(started)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    XCTAssertLessThan(elapsed, BackgroundRuns.shutdownTimeout + 0.5)
    XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH, "孫まで止まっている")
    XCTAssertFalse(waitingCompleted, "順番待ちの分は走らせない")
  }

  // MARK: - agent

  /// claude は契約どおりの引数で起こし、依頼文は標準入力で渡し、最後の `result` を最終応答として受け取る。
  func testClaudeRunsWithTheContractAndReturnsTheFinalReply() throws {
    try placeClaude(
      #"""
      echo '{"type":"system","subtype":"init","tools":[]}'
      echo '{"type":"assistant","message":{}}'
      echo '{"is_error":false,"result":"{\"ok\":true}","type":"result"}'
      """#)

    let result = try run(runs(), agent(tools: ["Read"]))

    XCTAssertEqual(result.ending, .exited(0))
    XCTAssertEqual(reply(result), BackgroundAgentReply(text: #"{"ok":true}"#, isError: false))
    XCTAssertEqual(
      try receivedArguments(), ClaudeHeadless.arguments(model: "haiku", tools: ["Read"]))
    XCTAssertEqual(
      try String(contentsOf: bin.appendingPathComponent("stdin"), encoding: .utf8), "判定して")
    XCTAssertTrue(
      result.commandLine.hasPrefix(bin.appendingPathComponent("claude").path + " -p --model haiku"),
      result.commandLine)
    XCTAssertTrue(result.commandLine.contains("--setting-sources '' "), result.commandLine)
  }

  func testClaudeFailureIsReported() throws {
    try placeClaude(#"echo '{"type":"result","is_error":true,"result":"overloaded"}'; exit 1"#)

    let result = try run(runs(), agent())

    XCTAssertEqual(result.ending, .exited(1))
    XCTAssertEqual(reply(result), BackgroundAgentReply(text: "overloaded", isError: true))
  }

  /// 最終応答が上限を超えたら打ち切る（切れた応答を完全なものとして読ませない）。
  func testReplyOverTheOutputLimitIsCutOff() throws {
    try placeClaude(#"echo '{"type":"result","is_error":false,"result":"0123456789abc"}'"#)
    var job = agent()
    job.limits.output = 10

    let result = try run(runs(), job)

    XCTAssertEqual(result.ending, .limited(.output))
    XCTAssertNil(reply(result))
  }

  /// 1 行の上限を超えて捨てた行が最終応答だったら、応答を失ったのは出力の上限による。
  func testOversizedResultLineIsAnOutputLimit() throws {
    let size = BackgroundRuns.eventLineLimit + 1
    try placeClaude(
      #"printf '{"type":"result","result":"'; head -c \#(size) /dev/zero | tr '\0' a; printf '"}\n'"#
    )

    let result = try run(runs(), agent())

    XCTAssertEqual(result.ending, .limited(.output))
    XCTAssertNil(reply(result))
  }

  /// agent の標準エラーは成果ではない。上限を超えても打ち切らず、最終応答を受け取る。
  func testAgentStderrOverTheLimitDoesNotCutTheRun() throws {
    try placeClaude(
      #"head -c 5000 /dev/zero >&2; echo '{"type":"result","is_error":false,"result":"ok"}'"#)
    var job = agent()
    job.limits.stderr = 100

    let result = try run(runs(), job)

    XCTAssertEqual(result.ending, .exited(0))
    XCTAssertEqual(reply(result), BackgroundAgentReply(text: "ok", isError: false))
  }

  func testCodexAndAgyAreRefusedWithReasons() throws {
    XCTAssertEqual(
      try run(runs(), agent("codex")).ending,
      .notStarted(.agentUnsupported(cli: "codex", reason: .toolsNotAllowListable)))
    XCTAssertEqual(
      try run(runs(), agent("agy")).ending,
      .notStarted(.agentUnsupported(cli: "agy", reason: .noToolOrSessionControl)))
  }

  func testMissingClaudeIsNotFound() throws {
    XCTAssertEqual(
      try run(runs(withBin: false), agent()).ending, .notStarted(.agentNotFound("claude")))
  }
}
