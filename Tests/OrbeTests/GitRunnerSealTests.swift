import OrbeTestSupport
import XCTest

@testable import Orbe

/// 対話の封じ: 全 git 呼び出しで、エディタと ssh の対話（パスフレーズ・未知のホスト鍵）は待たずに失敗する。対話は GUI
/// から見えず、書き込みは打ち切らないので、封じが外れると止める手を押すまで返らない。ただし利用者が配った GUI の askpass は
/// そのまま使う（外すと、それで通っていた ssh の認証・ホスト鍵の確かめが失敗する）。人が見ていない裏の fetch だけは、GUI の
/// askpass も資格情報の helper の対話も使わない（使うと、周期ごとに窓が出る）。リモートの失敗の分類も持つ。
@MainActor
final class GitRunnerSealTests: OrbeTestCase {
  var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  /// エディタが要る経路（メッセージ無しの commit）は、ユーザーのエディタが返らないものでも待たずに失敗する。
  func testAnEditorIsNeverWaitedFor() throws {
    let fixture = try GitHangFixture()
    defer { fixture.release() }
    let editor = try fixture.installScript("editor.sh", body: fixture.waitingBody)
    XCTAssertTrue(repo.git(["config", "core.editor", editor]).isSuccess)
    try repo.write("a.txt", "changed\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    var output: GitRunner.Output?
    let started = Date()
    GitRunner.shared.run(["commit"], cwd: repo.root, timesOut: false) { output = $0 }
    pumpMain(until: { output != nil }, timeout: 10, "エディタを待たない")
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    XCTAssertEqual(output?.isSuccess, false)
  }

  /// ssh を起こす経路で fetch し、記録用の `core.sshCommand` が受け取った環境変数 `names` の値を 1 行ずつ返す（既定は
  /// `SSH_ASKPASS_REQUIRE` と `SSH_ASKPASS`）。`unattended` なら裏の fetch。
  private func fetchRecordingSsh(
    unattended: Bool = false, recording names: [String] = ["SSH_ASKPASS_REQUIRE", "SSH_ASKPASS"]
  ) throws -> (env: String, failure: GitWriteFailure?) {
    let record = TestScratch.caseDir.appendingPathComponent("ssh-env").path
    let script = TestScratch.caseDir.appendingPathComponent("record-ssh.sh").path
    let values = names.map { "\"$\($0)\"" }.joined(separator: " ")
    try """
    #!/bin/sh
    printf '%s\\n' \(values) > "\(record)"
    echo 'recorded' >&2
    exit 1
    """.write(toFile: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    XCTAssertTrue(repo.git(["config", "core.sshCommand", script]).isSuccess)
    XCTAssertTrue(
      repo.git(["remote", "add", "origin", "ssh://git@example.invalid/r.git"]).isSuccess)
    let files = repo.files()
    let outcome = WriteOutcome()

    files.fetch(unattended: unattended, onProgress: { _ in }, completion: outcome.receive)
    pumpMain(until: { outcome.finished }, timeout: 20)
    return (try String(contentsOfFile: record, encoding: .utf8), outcome.failure)
  }

  /// ssh を起こす経路で、ssh に「対話できない」設定が届く（`core.sshCommand` に置いた記録用のスクリプトで観察する）。
  func testSshIsToldItCannotAsk() throws {
    let fetched = try fetchRecordingSsh()
    XCTAssertEqual(
      fetched.env, "force\n/usr/bin/false\n", "askpass を必ず使い、その askpass はすぐ失敗する")
    guard case .reason = fetched.failure else {
      return XCTFail("分類できない失敗は「その他」: \(String(describing: fetched.failure))")
    }
  }

  /// 利用者が配った GUI の askpass はそのまま使う（ダイアログで答えられるので待ちにならない）。
  func testTheUsersGuiAskpassIsKept() throws {
    setenv("SSH_ASKPASS", "/opt/gui-askpass", 1)
    defer { unsetenv("SSH_ASKPASS") }
    XCTAssertEqual(try fetchRecordingSsh().env, "force\n/opt/gui-askpass\n")
  }

  /// 裏の fetch（人が見ていない）は、利用者の GUI の askpass も使わず、資格情報の helper にも対話させない——周期ごとに
  /// 窓が出ない。
  func testAnUnattendedFetchNeverAsksEvenThroughTheUsersGuiAskpass() throws {
    setenv("SSH_ASKPASS", "/opt/gui-askpass", 1)
    setenv("GIT_ASKPASS", "/opt/gui-askpass", 1)
    defer {
      unsetenv("SSH_ASKPASS")
      unsetenv("GIT_ASKPASS")
    }
    let fetched = try fetchRecordingSsh(
      unattended: true, recording: ["SSH_ASKPASS", "GIT_ASKPASS", "GCM_INTERACTIVE"])
    XCTAssertEqual(fetched.env, "/usr/bin/false\n/usr/bin/false\nnever\n")
  }

  // MARK: - リモートの失敗の分類（stderr の字面で読むのは認証とホスト鍵だけ）

  // 標本は `/usr/bin/git`（2.54、Apple Git-157）と `/usr/bin/ssh` で github.com へ push して採ったもの（封じの環境の下）。

  private func failed(stderr: String, stdout: String = "") -> GitRunner.Output {
    GitRunner.Output(
      status: 128, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), ending: .completed,
      exited: true)
  }

  func testRemoteFailuresAreClassified() {
    XCTAssertEqual(
      GitWriteFailure.ofRemote(
        failed(
          stderr: """
            Load key "/dev/null": invalid format\r
            git@github.com: Permission denied (publickey).\r
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            and the repository exists.

            """)), .authentication)
    XCTAssertEqual(
      GitWriteFailure.ofRemote(
        failed(
          stderr: """
            Host key verification failed.
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            and the repository exists.

            """)), .unknownHostKey)
    XCTAssertEqual(
      GitWriteFailure.ofRemote(
        failed(
          stderr: """
            error: unable to read askpass response from '/usr/bin/false'
            fatal: could not read Username for 'https://github.com': terminal prompts disabled

            """)), .authentication)
    XCTAssertEqual(
      GitWriteFailure.ofRemote(
        failed(stderr: "fatal: 'nowhere' does not appear to be a git repository\n")),
      .reason("fatal: 'nowhere' does not appear to be a git repository"))
    XCTAssertEqual(
      GitWriteFailure.ofRemote(
        GitRunner.Output(
          status: -1, stdout: Data(), stderr: Data(), ending: .cancelled, exited: true)),
      .cancelled)
  }
}
