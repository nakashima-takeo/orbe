import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// Changes の画面の、上のバーの右下の置き場の札（実 git）——最後の失敗は失敗の札に出て、× で消える。コミットのポップアップを
/// 開いたまま走り続けるコミットは、ポップアップの下の実行中の札に出て「止める」で止まる。ポップアップから押したコミットの
/// 失敗は、失敗の札に重ねて出ない。
///
/// 壊れると何が起きるか。プル・プッシュの失敗が画面に出ず、通ったと思い込む。× を押しても失敗の札が消えない。コミットを
/// 始めた時点でポップアップが閉じ、返らない hook のコミットをポップアップの下で止められない。コミットの失敗が、ポップアップの
/// 赤い行と失敗の札の両方に出る。
extension SourceControlPaneTests {
  /// 置き場に並ぶ物（ポップアップと札）の枠。置き場の座標で、上から並ぶ順。
  func dockItemFrames(_ hosted: Hosted) -> [CGRect] {
    hosted.pane.layoutSubtreeIfNeeded()
    flush(hosted.window)
    return hosted.pane.dockHost.itemFrames
  }

  /// 最後の失敗（upstream の無いブランチのプル）は失敗の札に出て、× で消える。
  func testAFailureShowsTheFailureCardAndItsCloseClearsIt() throws {
    let repo = try TempGitRepo()
    repo.addOrigin()
    XCTAssertTrue(repo.git(["branch", "--unset-upstream"]).isSuccess)
    let hosted = host(repo)
    let control = hosted.scm.control
    let dock = hosted.pane.dockHost
    hosted.pane.popup.close(.escape)
    placeOffscreen(hosted.window)
    pumpMain(until: { hosted.scm.branch != nil && hosted.scm.branch?.upstream == nil }, "ブランチ")

    control.pull()
    pumpMain(until: { control.failure != nil }, "プルの失敗")
    let card = try XCTUnwrap(
      dockItemFrames(hosted).first,
      "失敗が立った時点で、失敗の札が出ている。この時点で出ていなければ、同じ時点で札が出ないことを確かめる"
        + " testACommitFailureWhileThePopupIsOpenStaysOutOfTheCards も、確かめる時点として成り立たない")

    // × は札の右上の角から余白の内側に在る。
    let inset = Theme.Layout.editorCardClosePad + Theme.Layout.editorCardClose / 2
    try click(
      dock,
      at: NSPoint(x: card.maxX - inset, y: dock.isFlipped ? card.minY + inset : card.maxY - inset))
    pumpMain(until: { control.failure == nil }, "× で最後の失敗が消える")
  }

  /// ポップアップを開いたまま返らない hook でコミットが走り続けると、ポップアップの下に実行中の札が出て、その「止める」で
  /// 止まる。
  func testALongRunningCommitShowsTheRunningCardBelowThePopupAndItsStopStopsIt() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    let hang = try GitHangFixture()
    try hang.installScript("pre-commit", body: hang.waitingBody)
    XCTAssertTrue(repo.git(["config", "core.hooksPath", hang.dir.path]).isSuccess)
    let hosted = host(repo)
    let control = hosted.scm.control
    placeOffscreen(hosted.window)
    pumpMain(until: { hosted.scm.changes.staged.count == 1 }, "ステージ済みの行")

    control.message = "wip"
    hosted.scm.commitSnapshot().commit()
    XCTAssertTrue(hang.pumpUntilHung(), "前提: hook が返らない")
    pumpMain(until: { self.dockItemFrames(hosted).count == 2 }, "ポップアップと実行中の札")
    let card = try XCTUnwrap(dockItemFrames(hosted).last, "実行中の札はポップアップの下")
    XCTAssertTrue(hosted.pane.popup.isOpen, "走っている間もポップアップは開いたまま")

    // 「止める」は札の右端に、札の右の余白を残して置かれる。
    try click(
      hosted.pane.dockHost,
      at: NSPoint(x: card.maxX - Theme.Layout.editorRunningPadTrailing - 4, y: card.midY))
    pumpMain(until: { control.operations.isEmpty }, "「止める」で止まる")
    XCTAssertNil(control.failure, "止めたコミットは失敗にならない")
    hang.release()
  }

  /// ポップアップから押したコミットが失敗しても、置き場にはポップアップだけが並ぶ（失敗はポップアップの赤い行に出し、失敗の
  /// 札には出さない）。札が出ないことは、失敗が立った時点で確かめる。同じ時点で札が出ることは、対の
  /// `testAFailureShowsTheFailureCardAndItsCloseClearsIt` が確かめる。
  func testACommitFailureWhileThePopupIsOpenStaysOutOfTheCards() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    let hook = repo.dir.appendingPathComponent(".git/hooks/pre-commit")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    let hosted = host(repo)
    let control = hosted.scm.control
    pumpMain(until: { hosted.scm.changes.staged.count == 1 }, "ステージ済みの行")

    control.message = "wip"
    hosted.scm.commitSnapshot().commit()
    pumpMain(until: { control.failure != nil }, "コミットの失敗")
    XCTAssertTrue(hosted.pane.popup.isOpen, "前提: 失敗したコミットのポップアップは開いたまま")
    XCTAssertEqual(dockItemFrames(hosted).count, 1, "置き場にはポップアップだけ")
  }
}
