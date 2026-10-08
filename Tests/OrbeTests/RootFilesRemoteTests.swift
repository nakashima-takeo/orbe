import OrbeTestSupport
import XCTest

@testable import Orbe

/// 根のサービスのリモートの書き込み（実 git・ローカルの bare リモート）: push・pull・fetch と失敗の分類・進捗・前提の判定。
///
/// 壊れると何が起きるか。upstream の無いブランチを送れない・送れても upstream が付かず次から pull できない・拒否と認証の
/// 失敗が同じ文で出て何をすべきか分からない・競合で止まったのに「失敗」としか言えない・fetch しても遅れの数が動かない・
/// 長い push の間に何も出ず固まって見える。
@MainActor
final class RootFilesRemoteTests: OrbeTestCase {
  var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  private func finish(
    _ files: RootFiles, _ start: (@escaping (GitWriteFailure?) -> Void) -> RootFiles.Write,
    file: StaticString = #filePath, line: UInt = #line
  ) -> WriteOutcome {
    let outcome = WriteOutcome(files)
    _ = start(outcome.receive)
    pumpMain(until: { outcome.finished }, timeout: 20, "書き込みの完了", file: file, line: line)
    return outcome
  }

  private func commit(_ path: String, _ text: String) throws {
    try repo.write(path, text)
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "local \(path)"]).isSuccess)
  }

  // MARK: - push

  /// upstream の無いブランチは origin へ upstream を付けて出る。進捗の行が途中で届く。
  func testPushingABranchWithoutUpstreamPublishesItToOrigin() throws {
    let bare = repo.addOrigin()
    XCTAssertTrue(repo.git(["checkout", "-q", "-b", "feat"]).isSuccess)
    try commit("f.txt", String(repeating: "payload\n", count: 1000))
    let files = repo.files()
    var progress: [String] = []

    let pushed = finish(files) { files.push(onProgress: { progress.append($0) }, completion: $0) }
    XCTAssertNil(pushed.failure)
    XCTAssertEqual(
      pushed.statusAtCompletion?.branch?.upstream,
      GitStatus.Upstream(name: "origin/feat", divergence: GitStatus.Divergence(ahead: 0, behind: 0))
    )
    XCTAssertEqual(
      repo.git(["rev-parse", "refs/heads/feat"], in: bare).stdoutText, repo.head() + "\n")
    XCTAssertTrue(progress.contains { $0.contains("objects") }, "進捗の行: \(progress)")
  }

  /// upstream があれば `git push` がユーザーの設定のまま送る。他から進んだリモートへの push は「拒否された」。
  func testPushingToAnAdvancedRemoteIsRejected() throws {
    repo.addOrigin()
    try commit("b.txt", "b\n")
    let files = repo.files()
    XCTAssertNil(finish(files) { files.push(onProgress: { _ in }, completion: $0) }.failure)

    try repo.advanceOrigin(writing: "o.txt", "o\n")
    try commit("c.txt", "c\n")
    XCTAssertEqual(
      finish(files) { files.push(onProgress: { _ in }, completion: $0) }.failure, .pushRejected)
  }

  /// サーバの hook が断った push は「拒否された（先に取り込みが要る）」ではなく、サーバの理由のままの「その他」。
  func testAPushDeclinedByTheServerKeepsItsReason() throws {
    let bare = repo.addOrigin()
    try repo.write(
      "hooks/pre-receive", "#!/bin/sh\necho 'protected branch' >&2\nexit 1\n", in: bare)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: bare + "/hooks/pre-receive")
    try commit("b.txt", "b\n")
    let files = repo.files()

    let pushed = finish(files) { files.push(onProgress: { _ in }, completion: $0) }
    guard case .reason(let reason) = pushed.failure else {
      return XCTFail("「その他」の失敗: \(String(describing: pushed.failure))")
    }
    XCTAssertTrue(reason.contains("pre-receive hook declined"), reason)
  }

  // MARK: - pull・fetch

  /// fetch で遅れの数が増え、pull で取り込める。
  func testFetchCountsTheRemoteAndPullBringsItIn() throws {
    repo.addOrigin()
    try repo.advanceOrigin(writing: "o.txt", "o\n")
    let files = repo.files()
    var progress: [String] = []

    let fetched = finish(files) { files.fetch(onProgress: { progress.append($0) }, completion: $0) }
    XCTAssertNil(fetched.failure)
    XCTAssertEqual(
      fetched.statusAtCompletion?.branch?.upstream?.divergence,
      GitStatus.Divergence(ahead: 0, behind: 1))
    XCTAssertFalse(progress.isEmpty, "進捗の行が届く")

    let pulled = finish(files) { files.pull(onProgress: { _ in }, completion: $0) }
    XCTAssertNil(pulled.failure)
    XCTAssertEqual(
      pulled.statusAtCompletion?.branch?.upstream?.divergence,
      GitStatus.Divergence(ahead: 0, behind: 0))
    XCTAssertEqual(try String(contentsOfFile: repo.root + "/o.txt", encoding: .utf8), "o\n")
  }

  /// pull が競合で止まると「競合で止まった」。
  func testAPullStoppedByAConflictIsClassified() throws {
    repo.addOrigin()
    XCTAssertTrue(repo.git(["config", "pull.rebase", "false"]).isSuccess)
    try repo.advanceOrigin(writing: "a.txt", "theirs\n")
    try commit("a.txt", "mine\n")
    let files = repo.files()

    XCTAssertEqual(
      finish(files) { files.pull(onProgress: { _ in }, completion: $0) }.failure,
      .conflicted(.merge))
  }

  // MARK: - 前提

  /// 前提が欠けた操作は、git を起こす前に分類された失敗で返る——upstream の無いブランチの pull・merge の途中の pull・
  /// detached HEAD の push・push 先が無い push。
  func testMissingPreconditionsAreClassifiedUpFront() throws {
    let files = repo.files()
    XCTAssertEqual(
      finish(files) { files.pull(onProgress: { _ in }, completion: $0) }.failure, .noUpstream)
    XCTAssertEqual(
      finish(files) { files.push(onProgress: { _ in }, completion: $0) }.failure,
      .noPushDestination)

    XCTAssertTrue(repo.git(["checkout", "-q", "--detach"]).isSuccess)
    XCTAssertEqual(
      finish(files) { files.push(onProgress: { _ in }, completion: $0) }.failure, .detached)
    XCTAssertTrue(repo.git(["checkout", "-q", "main"]).isSuccess)

    repo.addOrigin()
    XCTAssertTrue(repo.git(["checkout", "-q", "-b", "side"]).isSuccess)
    try commit("a.txt", "side\n")
    XCTAssertTrue(repo.git(["checkout", "-q", "main"]).isSuccess)
    try commit("a.txt", "main\n")
    XCTAssertFalse(repo.git(["merge", "-q", "side"]).isSuccess, "前提: merge が競合で止まる")
    XCTAssertEqual(
      finish(files) { files.pull(onProgress: { _ in }, completion: $0) }.failure,
      .operationInProgress(.merge))
  }
}
