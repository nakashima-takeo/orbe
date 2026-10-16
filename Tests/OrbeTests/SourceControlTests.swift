import OrbeTestSupport
import XCTest

@testable import Orbe

/// worktree のソース管理の状態（実 git）: 操作の列・2 段の操作・止める・失敗の記録・メッセージ。
///
/// 壊れると何が起きるか。コミットが通ってもメッセージが残る（打ち足した分まで消える）・コミットしてプッシュが push しない・
/// 止めた 2 段目が走る・失敗の文が次の操作でも残る・順番待ちの操作が帯に出て、実際に止まっているコミットを隠す・ネット操作
/// 中に別のネット操作が始められる。
@MainActor
final class SourceControlTests: OrbeTestCase {
  var repo: TempGitRepo!
  var files: RootFiles!
  var control: SourceControl!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
    repo.addOrigin()
    files = RootFiles.shared(for: repo.root)
    pumpMain(until: { self.files.status != nil }, "status の初回取得")
    control = SourceControl.shared(for: repo.root)
  }

  private func idle(_ message: String) {
    pumpMain(until: { self.control.operations.isEmpty }, timeout: 20, message)
  }

  /// コミットが通ればメッセージは空になる。失敗ならメッセージも失敗の文も残り、次の操作を始めると失敗の文は消える。
  func testCommitClearsTheMessageAndFailuresClearOnTheNextOperation() throws {
    control.message = "nothing staged"
    control.commit()
    idle("ステージ済みの無いコミット")
    XCTAssertEqual(control.message, "nothing staged")
    XCTAssertNotNil(control.failure)
    try repo.write("a.txt", "two\n")
    control.stage([GitStatus.Row(path: "a.txt", originalPath: nil)])
    XCTAssertNil(control.failure)
    idle("ステージ")
    control.message = "second"
    control.commit()
    idle("コミット")
    XCTAssertEqual(control.message, "")
    XCTAssertNil(control.failure)
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "second\n")
  }

  /// コミットしてプッシュは、コミットが通れば push まで走り、ネット操作の間は「ネット操作中」になる。
  func testCommitAndPushPushesAfterTheCommit() throws {
    try repo.write("a.txt", "two\n")
    control.stage([GitStatus.Row(path: "a.txt", originalPath: nil)])
    idle("ステージ")
    control.message = "pushed"
    control.commitAndPush()
    XCTAssertTrue(control.isNetworking)
    idle("コミットしてプッシュ")
    XCTAssertNil(control.failure)
    XCTAssertEqual(
      repo.git(["rev-parse", "origin/main"]).stdoutText, repo.git(["rev-parse", "HEAD"]).stdoutText)
  }

  /// 返らない hook のコミットは 0.3 秒を超えると帯に出て、その後ろのステージ（順番待ち）は帯に出ない。止めると失敗に
  /// ならず、index.lock も残らない。
  func testBandShowsTheRunningOperationAndStopLeavesNoLock() throws {
    let hook = repo.dir.appendingPathComponent(".git/hooks/pre-commit")
    try Data("#!/bin/sh\nsleep 60\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try repo.write("a.txt", "two\n")
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { self.files.status?.entries["a.txt"]?.staged != nil }, "ステージ済み")
    control.message = "hang"
    control.commit()
    control.stage([GitStatus.Row(path: "b.txt", originalPath: nil)])
    pumpMain(until: { self.control.bandOperation != nil }, "帯")
    XCTAssertEqual(control.bandOperation?.kind, .commit)
    XCTAssertEqual(control.operations.count, 2)
    control.bandOperation?.stop()
    idle("止めたコミットと後ろのステージ")
    XCTAssertNil(control.failure)
    XCTAssertEqual(control.message, "hang")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: repo.dir.appendingPathComponent(".git/index.lock").path))
  }

  /// 同期は pull が通れば push する。upstream の無いブランチのプルは分類どおりの失敗になる。
  func testSyncPullsThenPushesAndAMissingUpstreamIsRecorded() throws {
    XCTAssertTrue(repo.git(["config", "pull.rebase", "false"]).isSuccess)
    try repo.advanceOrigin(writing: "c.txt", "c\n")
    try repo.write("d.txt", "d\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "local"]).isSuccess)
    XCTAssertTrue(repo.git(["fetch", "-q"]).isSuccess)
    control.sync()
    idle("同期")
    XCTAssertNil(control.failure)
    XCTAssertEqual(
      repo.git(["rev-parse", "origin/main"]).stdoutText, repo.git(["rev-parse", "HEAD"]).stdoutText)
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "lonely"]).isSuccess)
    pumpMain(until: { self.files.status?.branch?.name == "lonely" }, "ブランチ")
    control.pull()
    idle("upstream の無いプル")
    XCTAssertEqual(control.failure, SourceControl.Failure(kind: .pull, failure: .noUpstream))
  }
}
