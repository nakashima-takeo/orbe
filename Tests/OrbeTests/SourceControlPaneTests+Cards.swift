import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// Changes の画面の、上のバーの右下の置き場の札（実 git）——最後の失敗は失敗の札に出て、× で消える。
///
/// 壊れると何が起きるか。プル・プッシュの失敗が画面に出ず、通ったと思い込む。× を押しても失敗の札が消えない。
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
    let card = try XCTUnwrap(dockItemFrames(hosted).first, "失敗が立った時点で、失敗の札が出ている")

    // × は札の右上の角から余白の内側に在る。
    let inset = Theme.Layout.editorCardClosePad + Theme.Layout.editorCardClose / 2
    try click(
      dock,
      at: NSPoint(x: card.maxX - inset, y: dock.isFlipped ? card.minY + inset : card.maxY - inset))
    pumpMain(until: { control.failure == nil }, "× で最後の失敗が消える")
  }
}
