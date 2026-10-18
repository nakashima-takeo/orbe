import OrbeTestSupport
import XCTest

@testable import Orbe

/// worktree のソース管理の状態（実 git）: 操作の列・2 段の操作・止める・失敗の記録・メッセージ。
///
/// 壊れると何が起きるか。コミットが通ってもメッセージが残る・コミットの間に打ち足した分まで消える・コミットしてプッシュが
/// push しない・コミットが通らなかったのに前からある未 push のコミットを push する・失敗の文が次の操作でも残る・順番待ちの
/// 操作が帯に出て、実際に止まっているコミットを隠す・同じ worktree でネット操作が重なる・push と並んで
/// amend・取り消しが走り、push したコミットを書き換える。
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
    control.commit(.staged())
    idle("ステージ済みの無いコミット")
    XCTAssertEqual(control.message, "nothing staged")
    XCTAssertNotNil(control.failure)
    try repo.write("a.txt", "two\n")
    control.stage([GitStatus.Row(path: "a.txt", originalPath: nil)])
    XCTAssertNil(control.failure)
    idle("ステージ")
    control.message = "second"
    control.commit(.staged("a.txt"))
    idle("コミット")
    XCTAssertEqual(control.message, "")
    XCTAssertNil(control.failure)
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "second\n")
  }

  /// コミットの間に打ち足したメッセージは、コミットが通っても消さない。
  func testAMessageEditedDuringTheCommitIsKept() throws {
    try repo.write("a.txt", "two\n")
    control.stage([GitStatus.Row(path: "a.txt", originalPath: nil)])
    idle("ステージ")
    control.message = "first"
    control.commit(.staged("a.txt"))
    control.message = "first, then more"
    idle("コミット")
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "first\n")
    XCTAssertEqual(control.message, "first, then more")
  }

  /// コミットしてプッシュは、コミットが通れば push まで走り、ネット操作の間は「ネット操作中」になる。
  func testCommitAndPushPushesAfterTheCommit() throws {
    try repo.write("a.txt", "two\n")
    control.stage([GitStatus.Row(path: "a.txt", originalPath: nil)])
    idle("ステージ")
    control.message = "pushed"
    control.commitAndPush(.staged("a.txt"))
    XCTAssertTrue(control.isNetworking)
    idle("コミットしてプッシュ")
    XCTAssertNil(control.failure)
    XCTAssertEqual(
      repo.git(["rev-parse", "origin/main"]).stdoutText, repo.git(["rev-parse", "HEAD"]).stdoutText)
  }

  /// コミットしてプッシュは、コミットが通らなければ push しない（前からある未 push のコミットを送らない）。
  func testCommitAndPushDoesNotPushWhenTheCommitFails() throws {
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "unpushed"]).isSuccess)
    let origin = repo.git(["rev-parse", "origin/main"]).stdoutText
    control.message = "nothing staged"
    control.commitAndPush(.staged())
    idle("ステージ済みの無いコミットしてプッシュ")
    XCTAssertEqual(control.failure?.kind, .commitAndPush)
    XCTAssertEqual(
      repo.git(["ls-remote", "origin", "main"]).stdoutText.prefix(40), origin.prefix(40))
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
    control.commit(.staged("a.txt"))
    control.stage([GitStatus.Row(path: "b.txt", originalPath: nil)])
    pumpMain(until: { self.control.bandOperation != nil }, "帯")
    XCTAssertEqual(control.bandOperation?.kind, .commit)
    XCTAssertEqual(control.operations.count, 2)
    control.bandOperation?.stop()
    idle("止めたコミットと後ろのステージ")
    XCTAssertNil(control.failure)
    XCTAssertEqual(control.message, "hang")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: repo.dir.appendingPathComponent(".git/index.lock").path))
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
    XCTAssertEqual(control.failure, SourceControl.Failure(kind: .pull, cause: .git(.noUpstream)))
  }

  /// ネット操作が列にある間、次のネット操作は始めずに断り、失敗の文で知らせる——ボタンの可否に頼らない（メニューを開いている
  /// 間に別の窓で始まった、などですり抜ける）。
  func testANetworkOperationIsRefusedWhileAnotherIsQueued() throws {
    let hook = repo.dir.appendingPathComponent(".git/hooks/pre-commit")
    try Data("#!/bin/sh\nsleep 60\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try repo.write("a.txt", "two\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { self.files.status?.entries["a.txt"]?.staged != nil }, "ステージ済み")
    control.message = "hang"
    control.commitAndPush(.staged("a.txt"))
    control.fetch()
    XCTAssertEqual(control.operations.map(\.kind), [.commitAndPush])
    XCTAssertEqual(control.failure, SourceControl.Failure(kind: .fetch, cause: .networkBusy))
    control.operations.first?.stop()
    idle("止めたコミットしてプッシュ")
  }

  /// push と HEAD の書き換えは並ばない——ネット操作が列にある間の amend・取り消しと、書き換えが列にある間のプッシュ・公開は
  /// 始めずに断る。書き換えの後に順番どおり走る pull・同期は断らない。
  func testPushAndRewritingTheHeadNeverOverlap() throws {
    let hook = repo.dir.appendingPathComponent(".git/hooks/pre-commit")
    try Data("#!/bin/sh\nsleep 60\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try repo.write("a.txt", "two\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { self.files.status?.entries["a.txt"]?.staged != nil }, "ステージ済み")
    control.message = "hang"

    control.commitAndPush(.staged("a.txt"))
    control.amend(.staged("a.txt"))
    XCTAssertEqual(
      control.failure, SourceControl.Failure(kind: .amend, cause: .rewriteDuringNetwork))
    control.undoLastCommit(.movedByOwnWrite)
    XCTAssertEqual(
      control.failure, SourceControl.Failure(kind: .undo, cause: .rewriteDuringNetwork))
    XCTAssertEqual(control.operations.map(\.kind), [.commitAndPush])
    control.operations.first?.stop()
    idle("止めたコミットしてプッシュ")

    control.amend(.staged("a.txt"))
    control.push()
    XCTAssertEqual(control.failure, SourceControl.Failure(kind: .push, cause: .pushDuringRewrite))
    control.publish()
    XCTAssertEqual(
      control.failure, SourceControl.Failure(kind: .publish, cause: .pushDuringRewrite))
    control.sync()
    XCTAssertEqual(control.operations.map(\.kind), [.amend, .sync])
    control.operations.forEach { $0.stop() }
    idle("止めた amend と同期")
  }
}
