import AppKit
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

  /// 出しているパネルで裏の fetch を走らせる。止めても終わりが遅れるように、ref を書く hook の最初の 1 回を、SIGTERM を
  /// 無視して git の stderr を握ったまま数秒眠るものにする（自然に終わる）。origin は 1 コミット進んでいる。
  private func panelWithAStubbornBackgroundFetch() throws -> (ScmPanel, ScmAutoFetch) {
    let repo = try TempGitRepo()
    repo.addOrigin()
    try repo.advanceOrigin(writing: "o.txt", "o\n")
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
    panel.commitAndPush()
    panel.control.stage([GitStatus.Row(path: "b.txt", originalPath: nil)])
    pumpMain(until: { panel.control.operations.isEmpty }, timeout: 20, "コミットしてプッシュとステージ")
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "a.txt\n")
    XCTAssertEqual(autoFetch.rules.humans, 0)
  }

  /// push の段の前の待ちも帯に出て止められ、止めればその場で終わる（コミットは残り、push はしない）。
  func testTheWaitBeforeThePushStepShowsTheBandAndStopsAtOnce() throws {
    let (panel, autoFetch) = try panelWithAStubbornBackgroundFetch()
    let repo = try XCTUnwrap(self.repo)
    try repo.write("a.txt", "edited\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { panel.changes.staged.count == 1 }, "a.txt がステージ済み")
    let origin = repo.git(["ls-remote", "origin", "main"]).stdoutText

    panel.control.message = "a"
    panel.commitAndPush()
    let operation = try XCTUnwrap(panel.control.operations.first)
    pumpMain(
      until: { panel.control.bandOperation === operation && operation.step == .push },
      timeout: 1.5, "push の段の前で待つ間も帯に出る")
    XCTAssertTrue(autoFetch.rules.isRunning, "前提: 裏の fetch はまだ終わっていない")
    XCTAssertFalse(panel.control.isCommitting, "コミットの段は終わっている")

    operation.stop()
    XCTAssertTrue(panel.control.operations.isEmpty, "裏の fetch の終わりを待たずに終わる")
    XCTAssertNil(panel.control.failure)
    XCTAssertEqual(autoFetch.rules.humans, 0)
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "a\n")
    XCTAssertEqual(repo.git(["ls-remote", "origin", "main"]).stdoutText, origin, "push しない")
  }
}
