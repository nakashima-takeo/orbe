import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 裏の fetch（実 git）: エディター面が見えていて Orbe が前面なら（ソース管理パネルを出していなくても）、手で何も押さなくても
/// 裏の fetch で先行・遅れが新しくなり、worktree の操作の列（帯・失敗の文・ボタンの可否）には出ない。
///
/// 壊れると何が起きるか。別の clone で origin が進んでも「同期 ↓N」に気づけない・3 分ごとに帯や失敗の文が出入りする。
@MainActor
final class ScmAutoFetchPanelTests: OrbeTestCase {
  private var panel: ScmPanel?
  /// 裏の fetch を粘らせたリポジトリ（`panelWithAStubbornBackgroundFetch` が作る）。
  private var repo: TempGitRepo?

  override func tearDown() {
    panel?.isShown = false
    panel?.isLive = false
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    super.tearDown()
  }

  func testAShownPanelInTheForegroundSeesTheRemoteAdvanceWithoutPressing() throws {
    let repo = try TempGitRepo()
    repo.addOrigin()
    try repo.advanceOrigin(writing: "o.txt", "o\n")
    let panel = ScmPanel(root: repo.root)
    self.panel = panel
    panel.isLive = true
    panel.isShown = true
    pumpMain(until: { panel.branch?.upstream?.divergence != nil }, "先行・遅れが出る")
    XCTAssertEqual(panel.branch?.upstream?.divergence?.behind, 0, "前提: まだ fetch していない")

    // テストのプロセスは前面にならないので、Orbe が前面に戻った知らせを送る。
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)

    pumpMain(
      until: { panel.branch?.upstream?.divergence?.behind == 1 }, timeout: 20, "裏の fetch で遅れが 1")
    XCTAssertTrue(panel.control.operations.isEmpty, "操作の列に載らない")
    XCTAssertNil(panel.control.failure)
  }

  /// ソース管理パネルを出していなくても、エディター面が見えていれば裏の fetch を欲しがり、遅れが新しくなる（件数は追従し、
  /// グラフと HEAD は読まない）。面が見えなくなれば欲しがらない。
  func testAVisiblePaneWithoutTheSourceControlPanelSeesTheRemoteAdvance() throws {
    let repo = try TempGitRepo()
    repo.addOrigin()
    try repo.advanceOrigin(writing: "o.txt", "o\n")
    let panel = ScmPanel(root: repo.root)
    self.panel = panel
    panel.isLive = true
    pumpMain(until: { panel.branch?.upstream?.divergence != nil }, "先行・遅れが出る")
    let autoFetch = ScmAutoFetch.shared(for: try XCTUnwrap(panel.liveFiles?.repo))
    XCTAssertTrue(autoFetch.rules.isWanted, "パネルを出していなくても欲しがる")

    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    pumpMain(
      until: { panel.branch?.upstream?.divergence?.behind == 1 }, timeout: 20, "裏の fetch で遅れが 1")
    XCTAssertNil(panel.graph, "パネルを出していない間はグラフを読まない")

    panel.isLive = false
    XCTAssertFalse(autoFetch.rules.isWanted, "面が見えなくなれば欲しがらない")
  }

  /// 認証で止まった裏の fetch は、面を隠している間に端末で remote 追跡 ref が動いていれば、次に面が見えたときに再開する。
  /// 面が見えている間に動いても、その知らせで再開する。値が止まった時点と同じなら（何も取れなかった外の fetch）止まったまま。
  func testAStoppedBackgroundFetchResumesWhenTheRemoteRefsMovedWhileThePaneWasHidden() throws {
    let repo = try TempGitRepo()
    repo.addOrigin()
    let script = TestScratch.caseDir.appendingPathComponent("denied-ssh.sh").path
    let log = TestScratch.caseDir.appendingPathComponent("ssh-attempts").path
    // 撃った回数は remote へ繋ぎにいった数。git が ssh の種類を確かめる `-G` は繋がないので数えない。
    try """
    #!/bin/sh
    [ "$1" = -G ] || echo attempt >> '\(log)'
    echo 'git@example.invalid: Permission denied (publickey).' >&2
    exit 255

    """.write(toFile: script, atomically: true, encoding: .utf8)
    let attempts = {
      ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    XCTAssertTrue(repo.git(["config", "core.sshCommand", script]).isSuccess)
    XCTAssertTrue(
      repo.git(["remote", "set-url", "origin", "ssh://git@example.invalid/r.git"]).isSuccess)
    let panel = ScmPanel(root: repo.root)
    self.panel = panel
    panel.isLive = true
    pumpMain(until: { panel.liveFiles?.repo != nil }, "根の git dir が分かる")
    let autoFetch = ScmAutoFetch.shared(for: try XCTUnwrap(panel.liveFiles?.repo))
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    pumpMain(
      until: { autoFetch.rules.isBlocked && autoFetch.rules.refsAtBlock != nil }, timeout: 20,
      "裏の fetch が認証で止まり、その時点の remote 追跡 ref を読む")

    panel.isLive = false
    panel.isLive = true
    pumpMain(until: { autoFetch.rules.isWanted }, "面がまた見える")
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    XCTAssertEqual(attempts(), 1, "値が同じなら止まったまま撃たない")

    panel.isLive = false
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "pushed"]).isSuccess)
    XCTAssertTrue(repo.git(["update-ref", "refs/remotes/origin/main", "HEAD"]).isSuccess)
    panel.isLive = true
    pumpMain(
      until: { attempts() == 2 && autoFetch.rules.isBlocked && autoFetch.rules.refsAtBlock != nil },
      timeout: 20,
      "再開した裏の fetch が撃つ（また認証で止まる）")

    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "pushed again"]).isSuccess)
    XCTAssertTrue(repo.git(["update-ref", "refs/remotes/origin/main", "HEAD"]).isSuccess)
    pumpMain(
      until: { attempts() == 3 }, timeout: 20, "面が見えている間に ref が動いた知らせでも再開する")
  }

  /// 出しているパネルで裏の fetch を走らせる。止めても終わりが遅れるように、ref を書く hook の最初の 1 回を、SIGTERM を
  /// 無視して git の stderr を握ったまま数秒眠るものにする（自然に終わる）。origin の `branch` が 1 コミット進んでいる。
  private func panelWithAStubbornBackgroundFetch(
    advancing branch: String = "main"
  ) throws -> (ScmPanel, ScmAutoFetch) {
    let repo = try TempGitRepo()
    repo.addOrigin()
    try repo.advanceOrigin(writing: "o.txt", "o\n", onto: branch)
    let hooks = repo.root + "-hooks"
    let started = hooks + "/started"
    try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
    let hook = hooks + "/reference-transaction"
    try "#!/bin/sh\n[ -e '\(started)' ] && exit 0\ntrap '' TERM\ntouch '\(started)'\nsleep 4\n"
      .write(
        toFile: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
    XCTAssertTrue(repo.git(["config", "core.hooksPath", hooks]).isSuccess)
    let panel = ScmPanel(root: repo.root)
    self.panel = panel
    panel.isLive = true
    panel.isShown = true
    pumpMain(until: { panel.liveFiles?.repo != nil }, "根の git dir が分かる")
    let autoFetch = ScmAutoFetch.shared(for: try XCTUnwrap(panel.liveFiles?.repo))
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    pumpMain(
      until: { autoFetch.rules.isRunning && FileManager.default.fileExists(atPath: started) },
      "裏の fetch が ref を書き始める")
    self.repo = repo
    return (panel, autoFetch)
  }

  /// 裏の fetch に譲って待つ人の操作は、待つ間も帯に出て止められる。止めると裏の fetch の終わりを待たずに「止めた」で
  /// 終わり、係の人の数は 0 に戻る。
  func testAHumanOperationWaitingForTheBackgroundFetchShowsTheBandAndStopsAtOnce() throws {
    let (panel, autoFetch) = try panelWithAStubbornBackgroundFetch()
    panel.control.fetch()
    XCTAssertEqual(autoFetch.rules.humans, 1)
    let operation = try XCTUnwrap(panel.control.operations.first)
    pumpMain(until: { panel.control.bandOperation === operation }, timeout: 1.5, "待つ間も帯に出る")
    XCTAssertTrue(autoFetch.rules.isRunning, "前提: 裏の fetch はまだ終わっていない")

    operation.stop()
    XCTAssertTrue(panel.control.operations.isEmpty, "裏の fetch の終わりを待たずに終わる")
    XCTAssertNil(panel.control.failure, "止めたのは失敗にしない")
    XCTAssertEqual(autoFetch.rules.humans, 0, "係の人の数が戻る")
    XCTAssertTrue(autoFetch.rules.isRunning)
    pumpMain(until: { !autoFetch.rules.isRunning }, "裏の fetch もやがて終わる")
    XCTAssertEqual(autoFetch.rules.humans, 0)
  }

  /// 止めなければ、裏の fetch が終わってから人の操作が走り、通る。
  func testAHumanOperationThatWaitedRunsAfterTheBackgroundFetch() throws {
    let (panel, autoFetch) = try panelWithAStubbornBackgroundFetch()
    panel.control.fetch()
    let operation = try XCTUnwrap(panel.control.operations.first)
    pumpMain(until: { panel.control.bandOperation === operation }, timeout: 1.5, "待つ間も帯に出る")

    pumpMain(until: { panel.control.operations.isEmpty }, timeout: 20, "待ちが明けて走り、終わる")
    XCTAssertNil(panel.control.failure)
    XCTAssertEqual(autoFetch.rules.humans, 0)
    pumpMain(until: { panel.branch?.upstream?.divergence?.behind == 1 }, "人の fetch が通った")
  }

  /// コミットしてプッシュは押した時点でコミットを順番に入れ、裏の fetch に譲って待つのは push の段の前だけ——待つ間に
  /// 押したステージはコミットの後に走り、コミットの中身は押した時点の姿のまま。
  func testCommitAndPushCommitsWhatWasShownWhileTheBackgroundFetchRuns() throws {
    let (panel, autoFetch) = try panelWithAStubbornBackgroundFetch()
    let repo = try XCTUnwrap(self.repo)
    try repo.write("a.txt", "edited\n")
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { panel.changes.staged.count == 1 }, "a.txt がステージ済み")
    XCTAssertTrue(autoFetch.rules.isRunning, "前提: 裏の fetch はまだ終わっていない")

    panel.control.message = "a only"
    panel.commitSnapshot().commitAndPush()
    panel.control.stage([GitStatus.Row(path: "b.txt", originalPath: nil)])
    pumpMain(until: { panel.control.operations.isEmpty }, timeout: 20, "コミットしてプッシュとステージ")
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "a.txt\n")
    XCTAssertEqual(autoFetch.rules.humans, 0)
  }

  /// push の段の前の待ちも帯に出て止められ、止めればその場で終わる（コミットは残り、裏の fetch が終わった後も push は
  /// 走らない）。origin の main は進めない——走れば通る push にしておく。
  func testTheWaitBeforeThePushStepShowsTheBandAndStopsAtOnce() throws {
    let (panel, autoFetch) = try panelWithAStubbornBackgroundFetch(advancing: "other")
    let repo = try XCTUnwrap(self.repo)
    try repo.write("a.txt", "edited\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { panel.changes.staged.count == 1 }, "a.txt がステージ済み")
    let origin = repo.git(["ls-remote", "origin", "main"]).stdoutText

    panel.control.message = "a"
    panel.commitSnapshot().commitAndPush()
    let operation = try XCTUnwrap(panel.control.operations.first)
    pumpMain(
      until: { panel.control.bandOperation === operation && operation.step == .network(.push) },
      timeout: 1.5, "push の段の前で待つ間も帯に出る")
    XCTAssertTrue(autoFetch.rules.isRunning, "前提: 裏の fetch はまだ終わっていない")
    XCTAssertFalse(panel.control.isCommitting, "コミットの段は終わっている")

    operation.stop()
    XCTAssertTrue(panel.control.operations.isEmpty, "裏の fetch の終わりを待たずに終わる")
    XCTAssertNil(panel.control.failure)
    XCTAssertEqual(autoFetch.rules.humans, 0)
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "a\n")
    pumpMain(until: { !autoFetch.rules.isRunning }, "裏の fetch が終わる")
    // 取り下げ損ねた待ちは裏の fetch の終わりで push を起こすので、その push が返るだけ回してから見る。
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    XCTAssertEqual(repo.git(["ls-remote", "origin", "main"]).stdoutText, origin, "push しない")
  }
}
