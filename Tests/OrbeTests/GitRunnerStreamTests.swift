import XCTest

@testable import Orbe

/// 流しながら読む実行——stdout を届いた塊ごとに欠けず順に渡して溜めない、無出力では打ち切らない（寿命は止める側が持つ）、
/// 止めれば SIGTERM で切って「止めた」として返る、起動できなければ「起動失敗」として返る、終われば出力の受け手を手放す。
///
/// 壊れると何が起きるか。一致の無い間は何も出さない grep が大きな根で黙って切られ、途中の結果に失敗の文が出る。止めた
/// 検索や根が消えた検索が「git が断った」と読まれる。止めても git が走り続ける。受け手が呼び出し側を掴んだまま残り、
/// 検索のたびにメモリが増える。
final class GitRunnerStreamTests: OrbeTestCase {
  /// 本番の 120 秒は待てないので、無出力の打ち切りが短い runner で「流す実行には効かない」ことを見る。
  private let runner = GitRunner(idleTimeout: 0.6)
  private var fixture: GitHangFixture!

  override func setUpWithError() throws {
    fixture = try GitHangFixture()
    addTeardownBlock { [fixture] in fixture?.cleanup() }
  }

  /// 塊の受け取りと終わりを記録する。受け手は裏のスレッドで呼ばれる。
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks = Data()
    private var output: GitRunner.Output?

    func receive(_ data: Data) { lock.withLock { chunks.append(data) } }

    func complete(_ output: GitRunner.Output) { lock.withLock { self.output = output } }

    var received: Data { lock.withLock { chunks } }
    var result: GitRunner.Output? { lock.withLock { output } }

    /// 終わりを `timeout` まで待つ（終わらなければ nil）。
    func awaitResult(timeout: TimeInterval) -> GitRunner.Output? {
      let deadline = Date().addingTimeInterval(timeout)
      while result == nil, Date() < deadline { usleep(10_000) }
      return result
    }
  }

  private func stream(_ args: [String], cwd: String? = nil, into recorder: Recorder)
    -> GitRunner.Stream
  {
    runner.stream(
      args, cwd: cwd ?? fixture.root, onOutput: recorder.receive, completion: recorder.complete)
  }

  /// hook が返らない commit を流す（無出力のまま止まる実行）。
  private func streamHangingCommit(body: String, into recorder: Recorder) throws -> GitRunner.Stream
  {
    try fixture.installHook("pre-commit", body: body)
    try "changed\n".write(
      toFile: (fixture.root as NSString).appendingPathComponent("a.txt"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(fixture.git(["add", "-A"]).isSuccess)
    let handle = stream(["commit", "-m", "blocked"], into: recorder)
    XCTAssertTrue(fixture.waitUntilHung(), "前提: hook の中で止まっている")
    return handle
  }

  func testEveryChunkArrivesInOrderAndNothingIsCollected() throws {
    let body = (0..<20_000).map { "line \($0)\n" }.joined()
    try body.write(
      toFile: (fixture.root as NSString).appendingPathComponent("big.txt"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(fixture.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(fixture.git(["commit", "-qm", "big"]).isSuccess)

    let recorder = Recorder()
    _ = stream(["show", "HEAD:big.txt"], into: recorder)
    let output = try XCTUnwrap(recorder.awaitResult(timeout: 20))

    XCTAssertEqual(String(bytes: recorder.received, encoding: .utf8), body, "塊は欠けず順に届く")
    XCTAssertEqual(output.ending, .completed)
    XCTAssertEqual(output.status, 0)
    XCTAssertEqual(output.stdout, Data(), "流した出力は溜めない")
  }

  /// 無出力が打ち切りの上限を超えて続いても切らず、終われば「完了」で返る。
  func testASilentRunIsNotCutAndCompletesWhenItEnds() throws {
    let recorder = Recorder()
    let handle = try streamHangingCommit(body: fixture.waitingBody, into: recorder)
    defer { handle.cancel() }
    XCTAssertNil(recorder.awaitResult(timeout: 1.5), "無出力が上限（0.6 秒）を超えても切らない")

    fixture.release()
    let output = recorder.awaitResult(timeout: 20)
    XCTAssertEqual(output?.ending, .completed)
    XCTAssertEqual(output?.status, 0)
  }

  /// 止めると SIGTERM で切り、孫が pipe を握っていても猶予の内に「止めた」で返る。何度止めてもよい。
  func testCancellingStopsTheRunAndReportsItWasCancelled() throws {
    let recorder = Recorder()
    let handle = try streamHangingCommit(body: fixture.pipeHoldingBody, into: recorder)
    let started = Date()
    handle.cancel()
    handle.cancel()
    let output = recorder.awaitResult(timeout: 10)
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "止めたら猶予の内に返る")
    XCTAssertEqual(output?.ending, .cancelled)
    XCTAssertEqual(output?.timedOut, false, "止めた実行を打ち切りと読ませない")
  }

  func testARunThatCannotStartReportsTheLaunchFailure() throws {
    let recorder = Recorder()
    _ = stream(["status"], cwd: fixture.dir.appendingPathComponent("gone").path, into: recorder)
    XCTAssertEqual(recorder.awaitResult(timeout: 10)?.ending, .launchFailed)
  }

  /// 終わった実行は出力の受け手を手放す——受け手が呼び出し側を掴み、呼び出し側が手を持っていても輪にならない。
  func testTheOutputHandlerIsReleasedWhenTheRunEnds() throws {
    final class Owner {}
    var owner: Owner? = Owner()
    weak let released = owner
    let finished = expectation(description: "completion")
    let handle = runner.stream(
      ["status", "--porcelain"], cwd: fixture.root,
      onOutput: { [owner] _ in _ = owner },
      completion: { _ in finished.fulfill() })
    owner = nil
    wait(for: [finished], timeout: 20)
    pumpMain(until: { released == nil }, "受け手が手放される")
    withExtendedLifetime(handle) {}
  }
}
