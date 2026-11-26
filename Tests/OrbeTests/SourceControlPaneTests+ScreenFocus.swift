import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 上のバーで Changes へ切り替えたときの焦点——左の列を開いていれば面が焦点を預かり、変更の列に行が出た時点で列へ渡す（その面で
/// 初めて Changes を出して、行がまだ組まれていないときも同じ）。同時に自動で開く diff は焦点を取らない。預かっている間に本体を
/// 押す・左の列を閉じると預かりは終わり、後から行が出ても列は焦点を取らない。左の列を閉じたまま切り替えれば本体へ移し、列へ
/// 焦点を求めない。
///
/// 壊れると何が起きるか。タブで初めて Changes を押した直後の ↑↓ が列に効かない。行と一緒に開いた diff が焦点を本文へ奪う。
/// 行を待つ間に本体を押した・左の列を閉じたのに、行が出た瞬間に列が焦点を奪う。閉じた左の列を開いた瞬間に列が焦点を奪う。
extension SourceControlPaneTests {
  /// 変更 a.txt・b.txt のリポジトリの面を Files の画面で載せ、本文に焦点を置いて、件数が出るまで待つ（Changes をまだ一度も
  /// 出していないので、変更の列の行は組まれていない）。
  private func paneBeforeTheFirstChanges() throws -> Hosted {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    try repo.write("b.txt", "new\n")
    let hosted = host(repo, showsPanel: false)
    hosted.window.makeFirstResponder(hosted.pane.focusTarget)
    pumpMain(until: { hosted.scm.count == 2 }, "前提: 件数が出る")
    return hosted
  }

  /// 自動で開いた diff の中身が出て、本体の焦点の行き先が diff の本文になった。
  private func diffIsShown(_ hosted: Hosted) -> Bool {
    hosted.pane.diff?.content == .ready && hosted.pane.focusTarget !== hosted.pane
  }

  /// 初めて Changes を出したとき、行が出た時点で変更の列に焦点が入り、同時に自動で開いた diff の中身が出ても列に残る。左の列を
  /// 閉じたまま切り替えれば本体の行き先へ移し、列へ焦点を求めない。
  func testTheFirstSwitchToChangesHandsTheFocusToTheListOnceItsRowsArrive() throws {
    let hosted = try paneBeforeTheFirstChanges()
    let pane = hosted.pane
    XCTAssertTrue(hosted.scm.layout.items.isEmpty, "前提: 行はまだ無い")

    pane.switchScreen(.changes)
    pumpMain(
      until: { self.diffIsShown(hosted) && hosted.window.firstResponder === pane.scmList.list },
      "行が出たら列に焦点が入り、diff が開いても列に残る")

    pane.switchScreen(.files)
    pane.toggleSidebar()
    pane.switchScreen(.changes)
    XCTAssertTrue(hosted.window.firstResponder === pane.focusTarget, "閉じていれば本体の行き先")
    XCTAssertFalse(hosted.scm.wantsListFocus, "列へ焦点を求めない")
  }

  /// 行を待つ間に本体を押すか左の列を閉じると、後から行が出ても列は焦点を取らず、焦点は自動で開いた diff の本文へ移る。
  func testPressingTheBodyOrClosingTheSidebarWhileWaitingKeepsTheListFromTakingTheFocus() throws {
    for (how, interrupt) in [
      (
        "本体を押す",
        { (pane: EditorPaneView, window: NSWindow) in
          pane.mouseDown(
            with: .mouse(
              .leftMouseDown, at: pane.convert(NSPoint(x: 600, y: 200), to: nil), in: window))
        }
      ),
      ("左の列を閉じる", { (pane: EditorPaneView, _: NSWindow) in pane.toggleSidebar() }),
    ] {
      let hosted = try paneBeforeTheFirstChanges()
      let pane = hosted.pane
      pane.switchScreen(.changes)
      interrupt(pane, hosted.window)

      pumpMain(
        until: { self.diffIsShown(hosted) && hosted.window.firstResponder === pane.focusTarget },
        "\(how): 焦点は diff の本文へ")
      XCTAssertFalse(hosted.scm.wantsListFocus, "\(how): 列へ焦点を求めない")
    }
  }
}
