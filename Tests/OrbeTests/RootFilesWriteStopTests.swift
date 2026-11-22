import OrbeTestSupport
import XCTest

@testable import Orbe

/// 書き込みを止める手。利用者が起こした書き込みは無出力で打ち切らず、止めるまで待つ（人が見ていない裏の fetch は打ち切る）。
/// 止めれば「止めた」で返り、`index.lock` を残さない。順番待ちの書き込みは、前の書き込みの終わりを待たずに git を起こさない
/// まま「止めた」で返る。
///
/// 壊れると何が起きるか。署名の pin 入力や重い hook の最中のコミットが 2 分で黙って切られる・止めても返らない・
/// 止めた後に `index.lock` が残って以後の git が全部落ちる・止めたはずのステージが後で走る。応答しない remote への裏の
/// fetch が返らず、そのリポジトリの自動 fetch が止まったままになる。
@MainActor
final class RootFilesWriteStopTests: OrbeTestCase {
  private var fixture: GitHangFixture!
  /// 根のサービスの git を走らせる runner の時計。本番の無出力の上限は、これを進めたときにだけ来る。
  private let clock = ManualClock()

  override func setUpWithError() throws {
    fixture = try GitHangFixture()
    addTeardownBlock { [fixture] in fixture?.release() }
  }

  private var root: String { GitWorktreeRoot.normalizedPath(fixture.root) }

  private var indexLock: String { root + "/.git/index.lock" }

  private func managed() -> RootFiles {
    let files = RootFiles(root: root, runner: GitRunner(clock: clock.waits))
    pumpMain(until: { files.status != nil }, "status の初回取得")
    return files
  }

  private func stageChange() throws {
    try "changed\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    XCTAssertTrue(fixture.git(["add", "a.txt"]).isSuccess)
  }

  /// 止めた書き込みが「止めた」で返り、`index.lock` を残さず、後続の git が通る。
  private func assertStopped(
    _ write: RootFiles.Write, _ outcome: WriteOutcome, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertTrue(fixture.pumpUntilHung(), "前提: 止まっている", file: file, line: line)
    XCTAssertTrue(
      clock.awaitSleeper(until: nil), "書き込みの待ち手は期限なしで眠る", file: file, line: line)
    clock.advance(by: 86_400)
    XCTAssertFalse(outcome.finished, "打ち切りの上限を過ぎても、止めるまでは返らない", file: file, line: line)
    write.cancel()
    write.cancel()
    pumpMain(until: { outcome.finished }, timeout: 10, "止めたら返る", file: file, line: line)
    XCTAssertEqual(outcome.failure, .cancelled, file: file, line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: indexLock), "index.lock を残さない", file: file, line: line)
    XCTAssertTrue(
      fixture.git(["status", "--porcelain"]).isSuccess, "後続の git が通る", file: file, line: line)
  }

  func testStoppingAHangingCommit() throws {
    try fixture.installHook("pre-commit", body: fixture.waitingBody)
    try stageChange()
    let files = managed()
    let outcome = WriteOutcome()
    let write = files.commit(
      message: "blocked", content: .staged("a.txt"), completion: outcome.receive)
    assertStopped(write, outcome)
  }

  /// clean filter で止まったステージは index.lock を握ったまま——止めれば git が自分で外す。
  func testStoppingAHangingStage() throws {
    let filter = try fixture.installScript("hang-filter.sh", body: fixture.waitingBody)
    XCTAssertTrue(fixture.git(["config", "filter.hang.clean", filter]).isSuccess)
    try "*.big filter=hang\n".write(
      toFile: root + "/.gitattributes", atomically: true, encoding: .utf8)
    try "payload\n".write(toFile: root + "/big.big", atomically: true, encoding: .utf8)
    let files = managed()
    let outcome = WriteOutcome()
    let write = files.stage(
      [GitStatus.Row(path: "big.big", originalPath: nil)], completion: outcome.receive)
    assertStopped(write, outcome)
  }

  /// 進捗の行は、push が終わるのを待たずに届く。
  func testStoppingAHangingPush() throws {
    let bare = fixture.dir.appendingPathComponent("origin.git").path
    XCTAssertTrue(fixture.git(["init", "-q", "--bare", bare]).isSuccess)
    XCTAssertTrue(fixture.git(["remote", "add", "origin", bare]).isSuccess)
    try fixture.installHook(
      "pre-push", body: "echo 'checking before push' >&2\n" + fixture.waitingBody)
    let files = managed()
    let outcome = WriteOutcome()
    var progress: [String] = []
    let write = files.push(onProgress: { progress.append($0) }, completion: outcome.receive)
    pumpMain(until: { progress.contains("checking before push") }, "進捗の行が途中で届く")
    assertStopped(write, outcome)
  }

  /// 無出力の上限を過ぎても、書き込みは打ち切られない。同じ runner の観測（smudge で止まった版の本文）は
  /// 打ち切られる——分かれ目は「止められる人が見ているか」。
  func testWritesAreNotTimedOutButObservationIs() throws {
    try fixture.installHook("pre-commit", body: fixture.waitingBody)
    try stageChange()
    let files = managed()
    let outcome = WriteOutcome()
    let write = files.commit(
      message: "slow hook", content: .staged("a.txt"), completion: outcome.receive)
    XCTAssertTrue(fixture.pumpUntilHung())

    let smudging = fixture.dir.appendingPathComponent("smudging").path
    let smudge = try fixture.installScript(
      "smudge.sh", body: ": > \"\(smudging)\"\nsleep 30")
    XCTAssertTrue(fixture.git(["config", "filter.slow.smudge", smudge]).isSuccess)
    try "*.txt filter=slow\n".write(
      toFile: root + "/.gitattributes", atomically: true, encoding: .utf8)
    var version: GitVersionText?
    files.repo?.version(of: "a.txt", atCommit: "HEAD") { version = $0 }
    pumpMain(
      until: { FileManager.default.fileExists(atPath: smudging) }, "前提: 観測が smudge で止まっている")
    fixture.expireIdleLimit(on: clock, until: { version != nil })
    XCTAssertEqual(version, .failed, "観測は打ち切られて返る")
    XCTAssertFalse(outcome.finished, "打ち切りの上限を過ぎても、書き込みは止めるまで待つ")

    write.cancel()
    pumpMain(until: { outcome.finished }, timeout: 10)
    XCTAssertEqual(outcome.failure, .cancelled)
  }

  /// 裏の fetch（人が見ていない）は、相手が無出力のまま返らなければ、止めなくても打ち切られて返る。
  func testAnUnattendedFetchIsTimedOut() throws {
    let helper = try fixture.installScript("hang-remote.sh", body: fixture.waitingBody)
    XCTAssertTrue(fixture.git(["config", "protocol.ext.allow", "always"]).isSuccess)
    XCTAssertTrue(fixture.git(["remote", "add", "origin", "ext::\(helper)"]).isSuccess)
    let files = managed()
    let outcome = WriteOutcome()

    _ = files.fetch(attended: false, onProgress: { _ in }, completion: outcome.receive)
    XCTAssertTrue(fixture.pumpUntilHung())
    fixture.expireIdleLimit(on: clock, until: { outcome.finished })
    XCTAssertTrue(outcome.finished, "止めずに返る")
    XCTAssertNotNil(outcome.failure)
    XCTAssertNotEqual(outcome.failure, .cancelled)
  }

  /// 人の fetch（見ている手）は、相手が無出力のまま返らなくても打ち切らず、止めるまで待つ。
  func testAHumanFetchIsNotTimedOut() throws {
    let helper = try fixture.installScript("hang-remote.sh", body: fixture.waitingBody)
    XCTAssertTrue(fixture.git(["config", "protocol.ext.allow", "always"]).isSuccess)
    XCTAssertTrue(fixture.git(["remote", "add", "origin", "ext::\(helper)"]).isSuccess)
    let files = managed()
    let outcome = WriteOutcome()
    let write = files.fetch(onProgress: { _ in }, completion: outcome.receive)
    assertStopped(write, outcome)
  }

  /// 書き込みが残っている間は、握る者が離れても根のサービスは生きていて（同じ根なら同じもの）完了を返し、走っていたものも
  /// 止めた順番待ちも返り終われば離れる（監視が残らない）。
  func testAServiceLivesUntilItsWritesReturn() throws {
    try fixture.installHook("pre-commit", body: fixture.waitingBody)
    try stageChange()
    var held: RootFiles? = RootFiles.shared(for: root)
    pumpMain(until: { held?.status != nil }, "status の初回取得")
    weak let observed = held
    let committed = WriteOutcome()
    let queued = WriteOutcome()
    held?.commit(message: "blocked", content: .staged("a.txt"), completion: committed.receive)
    XCTAssertTrue(fixture.pumpUntilHung())
    let write = held?.stage(
      [GitStatus.Row(path: "a.txt", originalPath: nil)], completion: queued.receive)
    held = nil

    XCTAssertNotNil(observed, "書き込み中は生きている")
    XCTAssertTrue(RootFiles.shared(for: root) === observed, "同じ根なら同じもの")
    write?.cancel()
    pumpMain(until: { queued.finished }, "止めた順番待ちが返る")
    fixture.release()
    pumpMain(until: { committed.finished }, timeout: 20, "握る者が離れても完了が返る")
    pumpMain(until: { observed == nil }, "返り終われば離れる")
  }

  /// 順番待ちの書き込みを止めると、前の書き込み（返らない hook）の終わりを待たずに「止めた」で返り、git を起こさない。
  func testStoppingAQueuedWriteReturnsAtOnceWithoutRunningGit() throws {
    try fixture.installHook("pre-commit", body: fixture.waitingBody)
    try stageChange()
    let files = managed()
    let first = WriteOutcome()
    files.commit(message: "blocked", content: .staged("a.txt"), completion: first.receive)
    XCTAssertTrue(fixture.pumpUntilHung())
    try "b\n".write(toFile: root + "/b.txt", atomically: true, encoding: .utf8)
    let queued = WriteOutcome()
    let write = files.stage(
      [GitStatus.Row(path: "b.txt", originalPath: nil)], completion: queued.receive)

    let started = Date()
    write.cancel()
    pumpMain(until: { queued.finished }, timeout: 5, "前の書き込みを待たずに返る")
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    XCTAssertEqual(queued.failure, .cancelled)
    XCTAssertFalse(first.finished, "前の書き込みはまだ止まっている")

    fixture.release()
    pumpMain(until: { first.finished }, timeout: 20)
    XCTAssertNil(first.failure)
    XCTAssertEqual(
      fixture.git(["status", "--porcelain", "--", "b.txt"]).stdoutText, "?? b.txt\n",
      "止めたステージは走らない")
  }
}
