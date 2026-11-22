import AppKit
import XCTest

@testable import Orbe

/// PR の画面——本体は、diff を開いていなければ今の PR の先頭のファイルの行の diff を出して、その行を選択表示し、worktree の今の
/// PR が替われば次の PR の diff に替わる。上段の現在地は、PR が分かるまでは根だけで、分かれば今の PR の番号と根。
///
/// 壊れると何が起きるか: PR の画面を出しても本体が空のまま。ブランチの PR が替わった後も前の PR の diff が本体に残り、もう今の
/// PR でない diff を見て確かめた気になる。上段の現在地が前の PR の番号のまま残る。
extension PullRequestPaneTests {
  /// レールで PR を出すと、diff を開いていなければ、今の PR の先頭のファイルの行の diff が本体に出て、その行が選択表示される。
  /// worktree の今の PR が替わると、前の PR の diff は本体から消え、次の PR の diff が出る。
  func testThePullRequestScreenShowsADiffOfTheCurrentPullRequest() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    let panel = hosted.pane.pullRequest
    pumpMain(until: { hosted.pane.diff != nil }, "本体に diff が出る")
    let first = try XCTUnwrap(hosted.pane.diff)
    guard case .pullRequest(let state) = first.id.kind else { return XCTFail("PR の diff") }
    XCTAssertEqual(state.key.id.number, 9)
    XCTAssertEqual(first.id.path, "src/a.swift", "列の先頭のファイルの行（フォルダ src の下）")
    XCTAssertEqual(panel.selection, .file(first.id.path))

    gitHub.number = 10
    panel.refresh()
    pumpMain(
      until: {
        guard case .pullRequest(let next)? = hosted.pane.diff?.id.kind else { return false }
        return next.key.id.number == 10
      }, "次の PR の diff に替わる")
  }

  /// PR の画面の上段の現在地は、PR が分かるまでは根だけで、分かれば今の PR の番号と根。今の PR が替われば、連が上位へ描き直しを
  /// 求め、番号が替わる。
  func testTheLocationOnThePullRequestScreenIsTheCurrentPullRequestAndTheRoot() throws {
    let root = try registeredRoot()
    let hosted = host(root)
    var redraws = 0
    hosted.tab.group.onLocationChange = { redraws += 1 }
    hosted.tab.group.editor.selectScreen(.pullRequest)
    XCTAssertEqual(hosted.tab.group.editorLocation, .root(root), "PR が分かるまでは根だけ")
    pumpMain(
      until: { hosted.tab.group.editorLocation == .pullRequest(number: 9, root: root) }, "今の PR と根")

    redraws = 0
    gitHub.number = 10
    hosted.pane.pullRequest.refresh()
    pumpMain(
      until: { hosted.tab.group.editorLocation == .pullRequest(number: 10, root: root) },
      "次の PR の番号")
    XCTAssertGreaterThan(redraws, 0, "上位へ描き直しを求める")
  }
}
