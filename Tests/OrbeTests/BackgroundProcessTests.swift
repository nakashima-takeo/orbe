import OrbeTestSupport
import XCTest

@testable import Orbe

/// 裏の 1 回——終わり方を見分け、3 つの上限で打ち切り、止めればグループごと止まり、正常に終わっても背景に残した孫ごと片付き、
/// pipe を握ったまま逃げた孫がいても返る。
///
/// 壊れると何が起きるか。返らない子を待つ予定が永久に止まる。打ち切ったはずの claude の子（MCP サーバー・ツールの実行）が
/// 生き残る。正常に終わった実行が背景に残したプロセスが、Orbe を終えるまで積み上がる。出力の上限が効かず、暴走した出力で
/// メモリを使い切る。
final class BackgroundProcessTests: OrbeTestCase {
  private func spec(
    _ script: String, elapsed: TimeInterval = 30, idle: TimeInterval = 30,
    stdout: BackgroundProcess.Stdout = .collect(.init(limit: 1 << 20, overflowStops: true)),
    stderr: BackgroundProcess.Capture = .init(limit: 1 << 20, overflowStops: true),
    stdin: Data? = nil
  ) -> BackgroundProcess.Spec {
    BackgroundProcess.Spec(
      executable: "/bin/sh", arguments: ["-c", script],
      environment: ProcessInfo.processInfo.environment, directory: TestScratch.caseDir.path,
      stdin: stdin, elapsedLimit: elapsed, idleLimit: idle, stdout: stdout, stderr: stderr)
  }

  /// 裏で走らせ、期限つきで受ける（返らない実装でテストプロセスを固めない）。
  private func run(
    _ process: BackgroundProcess, timeout: TimeInterval = 20
  ) throws -> (outcome: BackgroundProcess.Outcome, elapsed: TimeInterval) {
    var result: BackgroundProcess.Outcome?
    let done = expectation(description: "run")
    let started = Date()
    DispatchQueue.global().async {
      let outcome = process.run()
      DispatchQueue.main.async {
        result = outcome
        done.fulfill()
      }
    }
    wait(for: [done], timeout: timeout)
    return (try XCTUnwrap(result), Date().timeIntervalSince(started))
  }

  private func run(_ spec: BackgroundProcess.Spec) throws -> (
    outcome: BackgroundProcess.Outcome, elapsed: TimeInterval
  ) {
    try run(BackgroundProcess(spec))
  }

  private func text(_ captured: BackgroundProcess.Captured) -> String {
    String(bytes: captured.data, encoding: .utf8) ?? ""
  }

  private var pidFile: String { TestScratch.caseDir.appendingPathComponent("pid").path }

  /// 書かれた pid のプロセスが消えるまで待つ（launchd の回収までの遅れを吸う）。
  private func isGone(pidIn path: String, within timeout: TimeInterval = 3) throws -> Bool {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let pid = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if kill(pid, 0) == -1, errno == ESRCH { return true }
      usleep(20_000)
    }
    kill(pid, SIGKILL)
    return false
  }

  private func killProcess(pidIn path: String) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
      let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return }
    kill(pid, SIGKILL)
  }

  // MARK: - 終わり方

  func testExitCodeAndBothOutputsAreReturned() throws {
    let result = try run(spec("printf out; printf err >&2; exit 3"))

    XCTAssertEqual(result.outcome.ending, .exited(3))
    XCTAssertEqual(text(result.outcome.stdout), "out")
    XCTAssertEqual(text(result.outcome.stderr), "err")
  }

  func testDeathBySignalIsReported() throws {
    XCTAssertEqual(try run(spec("kill -KILL $$")).outcome.ending, .signaled(SIGKILL))
  }

  func testLaunchFailureIsReportedWithErrno() throws {
    var bad = spec("true")
    bad.executable = TestScratch.caseDir.appendingPathComponent("missing").path

    XCTAssertEqual(try run(bad).outcome.ending, .launchFailed(ENOENT))
  }

  func testStdinIsDeliveredAndClosed() throws {
    let result = try run(spec("cat", stdin: Data("依頼文".utf8)))

    XCTAssertEqual(result.outcome.ending, .exited(0))
    XCTAssertEqual(text(result.outcome.stdout), "依頼文")
  }

  /// 渡すデータが無ければ標準入力は空。読もうとする子が入力待ちで固まらない。
  func testStdinWithoutDataIsEmpty() throws {
    let result = try run(spec("cat; echo end", idle: 5))

    XCTAssertEqual(result.outcome.ending, .exited(0))
    XCTAssertEqual(text(result.outcome.stdout), "end\n")
  }

  /// Orbe のソケット・pty・他の実行の pipe を子に漏らさない。漏れると、子が握っている間は相手の EOF が来ない。
  func testOnlyStandardDescriptorsAreInherited() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&fds), 0, "前提: CLOEXEC の付いていない fd をこのプロセスが持っている")
    defer { fds.forEach { close($0) } }

    // 末尾の `true` は sh に lsof を exec させず、sh 自身の fd を見るため。
    let result = try run(spec("/usr/sbin/lsof -a -p $$ -d 0-1023 -F f; true"))

    let open = text(result.outcome.stdout).split(separator: "\n").filter { $0.hasPrefix("f") }
    XCTAssertEqual(open, ["f0", "f1", "f2"])
  }

  // MARK: - 上限

  func testElapsedLimitStopsEvenWhileOutputFlows() throws {
    let result = try run(spec("while :; do echo tick; sleep 0.1; done", elapsed: 0.5, idle: 5))

    XCTAssertEqual(result.outcome.ending, .limited(.elapsed))
    XCTAssertLessThan(result.elapsed, 5)
  }

  func testIdleLimitStopsSilentChild() throws {
    let result = try run(spec("sleep 30", idle: 0.5))

    XCTAssertEqual(result.outcome.ending, .limited(.idle))
    XCTAssertLessThan(result.elapsed, 5)
  }

  /// 出力が流れている間は、合計が無出力の上限を超えても切らない。
  func testOutputKeepsIdleLimitAway() throws {
    let result = try run(spec("for i in 1 2 3 4 5 6 7 8; do echo $i; sleep 0.1; done", idle: 0.5))

    XCTAssertEqual(result.outcome.ending, .exited(0))
  }

  /// 標準エラーへの出力も、生きている印として数える。
  func testStderrKeepsIdleLimitAway() throws {
    let result = try run(
      spec("for i in 1 2 3 4 5 6 7 8; do echo $i >&2; sleep 0.1; done", idle: 0.5))

    XCTAssertEqual(result.outcome.ending, .exited(0))
  }

  /// 貯める出力が上限を超えたら打ち切る。黙って捨てて走らせ続けると、切れた出力を完全なものとして読ませてしまう。
  func testStdoutOverflowStopsTheRun() throws {
    let result = try run(
      spec(
        "head -c 100000 /dev/zero; sleep 30",
        stdout: .collect(.init(limit: 1000, overflowStops: true))))

    XCTAssertEqual(result.outcome.ending, .limited(.output))
    XCTAssertEqual(result.outcome.stdout.data.count, 1000)
    XCTAssertTrue(result.outcome.stdout.truncated)
    XCTAssertLessThan(result.elapsed, 5)
  }

  func testStderrOverflowWithoutStopKeepsRunning() throws {
    let result = try run(
      spec(
        "head -c 5000 /dev/zero >&2; echo done", stderr: .init(limit: 100, overflowStops: false)))

    XCTAssertEqual(result.outcome.ending, .exited(0))
    XCTAssertEqual(result.outcome.stderr.data.count, 100)
    XCTAssertTrue(result.outcome.stderr.truncated)
    XCTAssertEqual(text(result.outcome.stdout), "done\n")
  }

  // MARK: - 行

  func testLinesAreDeliveredOneByOneAndOversizedLinesAreDropped() throws {
    let lines = LinesRecorder()
    let result = try run(
      spec(
        #"printf 'a\nbb\n'; head -c 100 /dev/zero | tr '\0' x; printf '\nc'"#,
        stdout: .lines(maxLength: 10, onLine: lines.receive)))

    XCTAssertEqual(result.outcome.ending, .exited(0))
    XCTAssertEqual(lines.received, ["a", "bb", "c"], "改行で終わらない最後の行も渡す")
    XCTAssertEqual(result.outcome.droppedLines, 1)
    XCTAssertTrue(result.outcome.stdout.data.isEmpty, "行で受ける出力は貯めない")
  }

  func testRefusedLineStopsWithOutputLimit() throws {
    let lines = LinesRecorder(refusing: "stop")
    let result = try run(
      spec("echo ok; echo stop; sleep 30", stdout: .lines(maxLength: 100, onLine: lines.receive)))

    XCTAssertEqual(result.outcome.ending, .limited(.output))
    XCTAssertLessThan(result.elapsed, 5)
  }

  // MARK: - 停止と片付け

  func testStopEndsTheRun() throws {
    let process = BackgroundProcess(spec("sleep 30"))
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { process.stop() }

    let result = try run(process)

    XCTAssertEqual(result.outcome.ending, .stopped)
    XCTAssertLessThan(result.elapsed, 5)
  }

  func testStopBeforeRunNeverLaunches() throws {
    let process = BackgroundProcess(spec("echo launched > \(pidFile)"))
    process.stop()

    XCTAssertEqual(try run(process).outcome.ending, .stopped)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile))
  }

  /// 止めると、子は SIGTERM を受けて後始末できる。GCD のワーカーから起こしても、そのスレッドのシグナルマスクを継がない。
  func testStoppedChildReceivesTerm() throws {
    let marker = TestScratch.caseDir.appendingPathComponent("term").path
    let process = BackgroundProcess(
      spec("trap 'echo got > \(marker); exit 0' TERM; sleep 30 & wait"))
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { process.stop() }

    XCTAssertEqual(try run(process).outcome.ending, .stopped)
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "SIGKILL を待たずに trap が走る")
  }

  /// Orbe は SIGPIPE を無視しているが、子では既定に戻す。無視を継ぐと、読み手の消えた pipe へ書き続ける。
  func testChildDoesNotInheritIgnoredSigpipe() throws {
    let previous = signal(SIGPIPE, SIG_IGN)
    defer { signal(SIGPIPE, previous) }

    XCTAssertEqual(try run(spec("kill -PIPE $$; exit 0")).outcome.ending, .signaled(SIGPIPE))
  }

  /// SIGTERM を無視する子も、猶予の後に SIGKILL で止まる。
  func testChildIgnoringTermIsKilled() throws {
    let process = BackgroundProcess(spec("trap '' TERM; sleep 30"))
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { process.stop() }

    let result = try run(process)

    XCTAssertEqual(result.outcome.ending, .stopped)
    XCTAssertLessThan(result.elapsed, 6)
  }

  /// 打ち切ると、グループにいる孫まで止まる。
  func testLimitStopsGrandchildren() throws {
    let result = try run(spec("sleep 30 & echo $! > \(pidFile); wait", idle: 0.5))

    XCTAssertEqual(result.outcome.ending, .limited(.idle))
    XCTAssertTrue(try isGone(pidIn: pidFile))
  }

  /// 正常に終わった実行が背景に残した孫も片付く（実行の寿命＝グループの寿命）。
  func testNormalExitCleansUpBackgroundGrandchildren() throws {
    let result = try run(spec("sleep 30 >/dev/null 2>&1 & echo $! > \(pidFile); exit 0"))

    XCTAssertEqual(result.outcome.ending, .exited(0))
    XCTAssertTrue(try isGone(pidIn: pidFile))
  }

  /// SIGTERM を無視して pipe を握る孫がいても、汲み出しの猶予で返り、孫は SIGKILL で止まる。
  func testGrandchildIgnoringTermAndHoldingPipeIsKilled() throws {
    let result = try run(spec("(trap '' TERM; exec sleep 30) & echo $! > \(pidFile); exit 0"))

    XCTAssertEqual(result.outcome.ending, .exited(0))
    XCTAssertLessThan(result.elapsed, 6)
    XCTAssertTrue(try isGone(pidIn: pidFile))
  }

  /// グループから逃げた孫（setsid）が pipe を握っていても、EOF を無期限に待たずに返る。
  func testEscapedGrandchildHoldingPipeDoesNotBlockReturn() throws {
    let script =
      #"/usr/bin/perl -e 'use POSIX; POSIX::setsid(); exec "sleep", "30";' & "#
      + "echo $! > \(pidFile); exit 0"
    let result = try run(spec(script))
    defer { killProcess(pidIn: pidFile) }

    XCTAssertEqual(result.outcome.ending, .exited(0))
    XCTAssertLessThan(result.elapsed, 6)
  }
}

/// 行の受け手。裏の直列キューで呼ばれる。
private final class LinesRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  private let refusing: String?

  init(refusing: String? = nil) {
    self.refusing = refusing
  }

  var received: [String] { lock.withLock { lines } }

  func receive(_ line: Data) -> Bool {
    let text = String(bytes: line, encoding: .utf8) ?? ""
    lock.withLock { lines.append(text) }
    return text != refusing
  }
}
