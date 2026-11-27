import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 変更が無くなったときの変更の列（実 git）——左の列に「変更なし」が出ても、列に在ったフォーカスは列に残る。
///
/// 壊れると何が起きるか。端末やエージェントが変更を全部コミット・破棄した瞬間に、フォーカスが窓へ落ち、キーがどこにも
/// 届かない。
extension SourceControlPaneTests {
  /// 変更の列にフォーカスがある間に、変更が外で無くなっても（作業ツリーを戻した）、フォーカスは列に残る。
  ///
  /// フォーカスが落ちる側の対が無い否定条件なので、列を外す形に変えるとこのテストが落ちることを確かめてから入れた。依っている
  /// 前提: 列が窓から外れてフォーカスが落ちるなら、それは「変更なし」を描く SwiftUI の更新（`flush`）の中で起きる。左の列の
  /// 組み方を変えたら、確かめ直す。
  func testTheListKeepsTheFocusWhenTheChangesAreGone() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    let scm = hosted.scm
    let list = hosted.pane.scmList.list
    pumpMain(until: { scm.changes.changes.count == 1 }, "変更の行")
    hosted.pane.popup.close(.escape)
    hosted.window.makeFirstResponder(list)
    XCTAssertTrue(hosted.window.firstResponder === list, "前提: 列にフォーカス")

    XCTAssertTrue(repo.git(["checkout", "--", "a.txt"]).isSuccess)
    pumpMain(until: { scm.listState == .none }, "変更なし")
    hosted.pane.layoutSubtreeIfNeeded()
    flush(hosted.window)
    nextTurn()
    XCTAssertTrue(hosted.window.firstResponder === list, "フォーカスは列に残る")
  }
}
