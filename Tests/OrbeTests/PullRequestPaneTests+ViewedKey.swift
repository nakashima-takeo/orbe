import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR のパネルの列に焦点があるときのキー v——列で選んでいるファイルが本体のファイルと違えば（↑↓ の直後で diff がまだ
/// 替わっていない間）、その diff を先に開いてから付け外しする。全体へのコメント欄で打っている間は、v は字として入る。面が
/// 列のために焦点を預かっている間は、v はどこにも届かない。
///
/// 壊れると何が起きるか: ↑↓ の直後に v を押すと、列で強調している行と違うファイルの確認済みを GitHub へ書く。全体への
/// コメント欄に v が打てない。焦点が列へ渡る前に押した v が、本体に残った diff（ブランチを切り替えた直後なら前のブランチの
/// PR のファイル）の確認済みを GitHub へ書く。
extension PullRequestPaneTests {
  func testVInTheListActsOnTheSelectedFile() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    pumpMain(until: { hosted.window.firstResponder === hosted.list }, "前提: 列に焦点")
    pumpMain(until: { hosted.pane.diff != nil }, "前提: 本体に diff が自動で開く")
    let state = try XCTUnwrap(hosted.pane.pullRequest.state)
    let shown = try XCTUnwrap(hosted.pane.diff).id.path
    let selected = shown == "b.swift" ? "src/a.swift" : "b.swift"
    hosted.pane.pullRequest.select(.file(selected))
    XCTAssertEqual(hosted.pane.diff?.id.path, shown, "前提: 選んだだけでは本体は替わらない")

    XCTAssertTrue(hosted.pane.handleViewedKey(.key("v", [])))
    XCTAssertEqual(hosted.pane.diff?.id.path, selected, "選んでいるファイルを先に開く")
    XCTAssertTrue(state.isViewed(selected))
    XCTAssertFalse(state.isViewed(shown))
    XCTAssertTrue(hosted.window.firstResponder === hosted.list, "焦点は列のまま")

    _ = try openReview(hosted)
    XCTAssertFalse(hosted.pane.handleViewedKey(.key("v", [])), "欄では字として入る")
    XCTAssertTrue(state.isViewed(selected))
  }

  /// PR の画面へ切り替えた直後、列がまだ焦点を受け取らず面が預かっている間は、v は本体の diff の確認済みを切り替えない。
  func testVWhileThePaneHoldsTheFocusForTheListDoesNothing() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    pumpMain(until: { hosted.pane.diff != nil }, "前提: 本体に diff が自動で開く")
    let state = try XCTUnwrap(hosted.pane.pullRequest.state)
    let shown = try XCTUnwrap(hosted.pane.diff).id.path
    hosted.pane.switchScreen(.files)
    hosted.pane.switchScreen(.pullRequest)
    XCTAssertEqual(hosted.pane.heldListFocus, .pullRequest, "前提: 面が焦点を預かる")
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane, "前提: 焦点は面自身")
    XCTAssertEqual(hosted.pane.diff?.id.path, shown, "前提: 本体は同じ diff")

    _ = hosted.pane.handleViewedKey(.key("v", []))
    XCTAssertFalse(state.isViewed(shown), "本体の diff の確認済みは変わらない")
  }
}
