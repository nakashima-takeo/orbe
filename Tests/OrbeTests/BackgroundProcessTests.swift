import OrbeTestSupport
import XCTest

@testable import Orbe

/// 裏の 1 回——終わり方を見分け、3 つの上限で打ち切り、止めればグループごと止まり、正常に終わっても背景に残した孫ごと片付き、
/// pipe を握ったまま逃げた孫がいても返る。
///
/// 壊れると何が起きるか。返らない子を待つ予定が永久に止まる。打ち切ったはずの claude の子（MCP サーバー・ツールの実行）が
/// 生き残る。正常に終わった実行が背景に残したプロセスが、Orbe を終えるまで積み上がる。出力の上限が効かず、暴走した出力で
/// メモリを使い切る。無出力の上限を外した実行が、出力の無い間に切られるか、経過時間を過ぎても止まらない。
final class BackgroundProcessTests: OrbeTestCase {
  /// 上限と猶予を見るテストは、手で進める時計を渡した実行（`timed`）で駆動する。上限と猶予は、時計を進めたときにだけ来る。
  let clock = ManualClock()
  /// 黙った子を無出力の上限で切るテストの、無出力の上限。経過の上限（既定の 30 秒）より短い。
  static let idleLimit: TimeInterval = 10
  func spec(
    _ script: String, elapsed: TimeInterval = 30, idle: TimeInterval? = 30,
    stdout: BackgroundProcess.Stdout = .collect(.init(limit: 1 << 20, overflowStops: true)),
    stderr: BackgroundProcess.Capture = .init(limit: 1 << 20, overflowStops: true),
    stdin: Data? = nil
  ) -> BackgroundProcess.Spec {
    BackgroundProcess.Spec(
      executable: "/bin/sh", arguments: ["-c", script],
      environment: ProcessInfo.processInfo.environment, directory: TestScratch.caseDir.path,
      stdin: stdin, elapsedLimit: elapsed, idleLimit: idle, stdout: stdout, stderr: stderr)
  }

  func timed(_ spec: BackgroundProcess.Spec) -> BackgroundProcess {
    BackgroundProcess(spec, clock: clock.timers)
  }

  /// 裏で走らせた `run` の結果。main で届く。
  final class Pending {
    var outcome: BackgroundProcess.Outcome?
  }

  /// `run` は終わりまで返らないので、裏で走らせる（時計を進める間、テストのスレッドを止めさせない）。
  func start(_ process: BackgroundProcess) -> Pending {
    let pending = Pending()
    DispatchQueue.global().async {
      let outcome = process.run()
      DispatchQueue.main.async { pending.outcome = outcome }
    }
    return pending
  }

  /// 裏で走らせた `run` の結果を、期限つきで受ける（返らない実装でテストプロセスを固めない）。
  func outcome(
    of pending: Pending, timeout: TimeInterval = 20, file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> BackgroundProcess.Outcome {
    pumpMain(
      until: { pending.outcome != nil }, timeout: timeout, "run が返る", file: file, line: line)
    return try XCTUnwrap(pending.outcome, file: file, line: line)
  }

  private func run(
    _ process: BackgroundProcess, timeout: TimeInterval = 20
  ) throws -> (outcome: BackgroundProcess.Outcome, elapsed: TimeInterval) {
    let started = Date()
    let outcome = try outcome(of: start(process), timeout: timeout)
    return (outcome, Date().timeIntervalSince(started))
  }

  private func run(_ spec: BackgroundProcess.Spec) throws -> (
    outcome: BackgroundProcess.Outcome, elapsed: TimeInterval
  ) {
    try run(BackgroundProcess(spec))
  }

  private func text(_ captured: BackgroundProcess.Captured) -> String {
    String(bytes: captured.data, encoding: .utf8) ?? ""
  }

  func scratch(_ name: String) -> String {
    TestScratch.caseDir.appendingPathComponent(name).path
  }

  private var pidFile: String { scratch("pid") }

  /// 直前に背景へ回した子の pid を、`pidFile` に置く。書き終えてからリネームするので、現れた時点で中身を読める。
  private var recordPID: String { "echo $! > '\(pidFile).tmp'; mv '\(pidFile).tmp' '\(pidFile)'" }

  /// テストが子へ出す合図のファイルを作る。
  func touch(_ path: String) {
    FileManager.default.createFile(atPath: path, contents: nil)
  }

  private func awaitFile(
    _ path: String, _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    pumpMain(
      until: { FileManager.default.fileExists(atPath: path) }, message, file: file, line: line)
  }

  private func pid(in path: String) throws -> pid_t {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    return try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  private func isAlive(pidIn path: String) throws -> Bool {
    kill(try pid(in: path), 0) == 0
  }

  /// 書かれた pid のプロセスが消えるまで待つ（launchd の回収までの遅れを吸う）。
  private func isGone(pidIn path: String, within timeout: TimeInterval = 3) throws -> Bool {
    let pid = try pid(in: path)
    if sleepUntil(timeout, { kill(pid, 0) == -1 && errno == ESRCH }) { return true }
    kill(pid, SIGKILL)
    return false
  }

  private func killProcess(pidIn path: String) {
    guard let pid = try? pid(in: path) else { return }
    kill(pid, SIGKILL)
  }

  /// 実行が始まり、上限の予約を張るのを待って、その予約を返す。
  func awaitLimit(file: StaticString = #filePath, line: UInt = #line) throws
    -> ManualClock.Reservation
  {
    try XCTUnwrap(clock.awaitReservation(), "前提: 上限の予約が張られる", file: file, line: line)
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

  /// 読み手が続ける意味を失った行では、出力の上限ではなく「止めた」で終わる。
  func testLineThatStopsTheRunEndsAsStopped() throws {
    let lines = LinesRecorder(refusing: "stop", with: .stopped)
    let result = try run(
      spec("echo ok; echo stop; sleep 30", stdout: .lines(maxLength: 100, onLine: lines.receive)))

    XCTAssertEqual(result.outcome.ending, .stopped)
    XCTAssertLessThan(result.elapsed, 5)
  }

  // MARK: - 停止と片付け

  func testStopEndsTheRun() throws {
    let ready = scratch("ready")
    let process = BackgroundProcess(spec(": > '\(ready)'; exec sleep 30"))
    let pending = start(process)
    awaitFile(ready, "前提: 子が起動している")

    process.stop()

    XCTAssertEqual(try outcome(of: pending).ending, .stopped)
  }

  func testStopBeforeRunNeverLaunches() throws {
    let process = BackgroundProcess(spec("echo launched > \(pidFile)"))
    process.stop()

    XCTAssertEqual(try run(process).outcome.ending, .stopped)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile))
  }

  /// 止めると、子は SIGTERM を受けて後始末できる。GCD のワーカーから起こしても、そのスレッドのシグナルマスクを継がない。
  func testStoppedChildReceivesTerm() throws {
    let marker = scratch("term")
    let ready = scratch("ready")
    let process = BackgroundProcess(
      spec("trap 'echo got > \(marker); exit 0' TERM; : > '\(ready)'; sleep 30 & wait"))
    let pending = start(process)
    awaitFile(ready, "前提: 子が SIGTERM の trap を設定している")

    process.stop()

    XCTAssertEqual(try outcome(of: pending).ending, .stopped)
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
    let ready = scratch("ready")
    let process = timed(spec("trap '' TERM; : > '\(ready)'; sleep 30"))
    let pending = start(process)
    awaitFile(ready, "前提: 子が SIGTERM を無視している")
    let limit = try awaitLimit()

    process.stop()
    let grace = try XCTUnwrap(
      clock.awaitReservation(where: { $0 != limit }), "止めた後、SIGKILL までの猶予の予約が張られる")
    clock.advance(to: grace.deadline)

    XCTAssertEqual(try outcome(of: pending).ending, .stopped)
  }

  /// 打ち切ると、グループにいる孫まで止まる。
  func testLimitStopsGrandchildren() throws {
    let pending = start(timed(spec("sleep 30 & \(recordPID); wait", idle: Self.idleLimit)))
    awaitFile(pidFile, "前提: 孫が起動している")
    clock.advance(to: try awaitLimit().deadline)

    XCTAssertEqual(try outcome(of: pending).ending, .limited(.idle))
    XCTAssertTrue(try isGone(pidIn: pidFile))
  }

  /// 正常に終わった実行が背景に残した孫も片付く（実行の寿命＝グループの寿命）。
  func testNormalExitCleansUpBackgroundGrandchildren() throws {
    let result = try run(spec("sleep 30 >/dev/null 2>&1 & echo $! > \(pidFile); exit 0"))

    XCTAssertEqual(result.outcome.ending, .exited(0))
    XCTAssertTrue(try isGone(pidIn: pidFile))
  }

  /// 孫が pipe を握ったまま子が終わる実行で、汲み出しの猶予の予約が張られるのを待つ。孫は、準備を終えた印を `ready` に置く。
  /// 子は、テストの合図で終わる（子が終わると上限の予約は取り消されるので、その前に受け取るため）。
  private func awaitDrainGrace(
    ready: String, file: StaticString = #filePath, line: UInt = #line
  ) throws -> ManualClock.Reservation {
    awaitFile(ready, "前提: 孫が準備を終えている", file: file, line: line)
    let limit = try awaitLimit(file: file, line: line)
    touch(scratch("exit"))
    return try XCTUnwrap(
      clock.awaitReservation(where: { $0 != limit }), "子が終わった後、汲み出しの猶予の予約が張られる",
      file: file, line: line)
  }

  private var exitOnSignal: String {
    "while [ ! -e '\(scratch("exit"))' ]; do sleep 0.05; done; exit 0"
  }

  /// SIGTERM を無視して pipe を握る孫がいても、汲み出しの猶予で返り、孫は SIGKILL で止まる。
  func testGrandchildIgnoringTermAndHoldingPipeIsKilled() throws {
    let ready = scratch("ready")
    let pending = start(
      timed(
        spec("(trap '' TERM; : > '\(ready)'; exec sleep 30) & \(recordPID); \(exitOnSignal)")))
    let drain = try awaitDrainGrace(ready: ready)
    XCTAssertTrue(
      try isAlive(pidIn: pidFile), "前提: 孫は SIGTERM を無視して、pipe を握ったまま生きている（EOF は来ていない）")

    clock.advance(to: drain.deadline)

    XCTAssertEqual(try outcome(of: pending).ending, .exited(0))
    XCTAssertTrue(try isGone(pidIn: pidFile))
  }

  /// グループから逃げた孫（setsid）が pipe を握っていても、EOF を無期限に待たずに返る。
  func testEscapedGrandchildHoldingPipeDoesNotBlockReturn() throws {
    let ready = scratch("ready")
    let script =
      #"/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(my $f, ">", $ARGV[0]); close($f); "#
      + #"exec "sleep", "30";' "# + "'\(ready)' & \(recordPID); \(exitOnSignal)"
    let pending = start(timed(spec(script)))
    defer { killProcess(pidIn: pidFile) }
    let drain = try awaitDrainGrace(ready: ready)

    clock.advance(to: drain.deadline)

    XCTAssertEqual(try outcome(of: pending).ending, .exited(0))
    XCTAssertTrue(
      try isAlive(pidIn: pidFile), "前提: 逃げた孫が pipe を握っていて EOF は来ていない（猶予で返った）")
  }
}

/// 行の受け手。裏の直列キューで呼ばれる。
private final class LinesRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  private let refusing: String?
  private let cut: BackgroundProcess.Ending

  init(refusing: String? = nil, with cut: BackgroundProcess.Ending = .limited(.output)) {
    self.refusing = refusing
    self.cut = cut
  }

  var received: [String] { lock.withLock { lines } }

  func receive(_ line: Data) -> BackgroundProcess.Ending? {
    let text = String(bytes: line, encoding: .utf8) ?? ""
    lock.withLock { lines.append(text) }
    return text == refusing ? cut : nil
  }
}
