import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR のパネルが今の PR を追う段と中身を読む段——面が見えていれば PR の画面を出していなくても今の PR を引き、中身は PR の画面を
/// 出してから読む。PR の画面へ切り替えたとき、答えか中身を読んでいる間は面が焦点を預かり、行が出た時点で焦点が列へ入る。PR が
/// 無いと分かれば預かりは終わる。
///
/// 壊れると何が起きるか: PR の画面を一度出すまで、上のバーに PR の番号が出ない。見ているだけの面のために PR の中身とスレッドを
/// GitHub から読む。初めて PR の画面を出した直後・中身の読みに失敗した後の出し直しで、行が出ても ↑↓ が列に効かない。PR が
/// 無いと分かった後も預かりが残り、ブラウザで PR を作って戻ると、何も押していないのに列が焦点を奪う。
extension PullRequestPaneTests {
  /// 面が見えていれば、PR の画面を一度も出していなくても今のブランチの PR を引く（上のバーの番号が出る）。中身は PR の画面を
  /// 出すまで読まない。
  func testAShownPaneTracksThePullRequestWithoutReadingItsContentUntilThePullRequestScreen() throws
  {
    let hosted = host(try registeredRoot())
    pumpMain(
      until: { hosted.pane.pullRequest.state?.key.id.number == self.gitHub.number },
      "Files の画面のままでも今の PR が分かる")
    let state = try XCTUnwrap(hosted.pane.pullRequest.state)
    XCTAssertFalse(state.isWatched, "PR の画面を出すまで中身は読まない")

    hosted.pane.switchScreen(.pullRequest)
    XCTAssertTrue(state.isWatched, "PR の画面を出せば中身を読む")
  }

  /// PR の画面へ切り替えたとき、今の PR の答えか中身をまだ読んでいる間は面が焦点を預かり、読めて行が出た時点で列に焦点が
  /// 入る（同時に自動で開く diff は焦点を取らない）。中身の読みに失敗した後で出し直したときも、読み直している間は預かる。
  func testSwitchingToThePullRequestWhileItIsReadFocusesTheListOnceItsRowsArrive() throws {
    func listGetsTheFocus(_ hosted: Hosted, _ message: String) {
      gitHub.release()
      pumpMain(
        until: { hosted.pane.diff != nil && hosted.window.firstResponder === hosted.list }, message)
    }

    gitHub.holdsLookups = true
    let first = host(try registeredRoot())
    pumpMain(until: { !self.gitHub.held.isEmpty }, "前提: 今の PR を問い合わせている")
    first.pane.switchScreen(.pullRequest)
    listGetsTheFocus(first, "今の PR の答えを待つ間に切り替えても、行が出たら列に焦点が入る")

    gitHub.holdsLookups = false
    gitHub.contentFails = true
    let again = host(try registeredRoot())
    pumpMain(until: { again.pane.pullRequest.state != nil }, "前提: 今の PR が分かる")
    let state = try XCTUnwrap(again.pane.pullRequest.state)
    again.pane.switchScreen(.pullRequest)
    pumpMain(until: { state.isWatched && !state.isReading }, "前提: 中身の読みが失敗で終わる")
    XCTAssertNil(state.content, "前提: 中身は無い")
    again.pane.switchScreen(.files)
    gitHub.contentFails = false
    gitHub.holdsContents = true
    again.pane.switchScreen(.pullRequest)
    pumpMain(until: { state.isReading }, "前提: 出し直すと読み直す")
    listGetsTheFocus(again, "失敗の後の出し直しでも、読めて行が出たら列に焦点が入る")
  }

  /// 今の PR の答えを読んでいる間に PR の画面へ切り替え、PR が無いと分かれば預かりは終わる——後で PR が現れて行が出ても
  /// （ブラウザで作って戻る）、列は焦点を取らない。
  func testFindingNoPullRequestWhileWaitingKeepsALaterPullRequestFromTakingTheFocus() throws {
    gitHub.holdsLookups = true
    gitHub.open = false
    let hosted = host(try registeredRoot())
    pumpMain(until: { !self.gitHub.held.isEmpty }, "前提: 今の PR を問い合わせている")
    hosted.pane.switchScreen(.pullRequest)
    gitHub.release()
    pumpMain(
      until: {
        if case .noPullRequest = hosted.pane.pullRequest.pullRequest.answer { true } else { false }
      }, "前提: PR が無いと分かる")

    gitHub.holdsLookups = false
    gitHub.open = true
    hosted.pane.pullRequest.refresh()
    pumpMain(
      until: {
        hosted.list.window != nil && hosted.pane.diff != nil
          && !hosted.pane.pullRequest.focusRequest
      }, "前提: PR が現れて列と diff が出る")
    XCTAssertFalse(hosted.window.firstResponder === hosted.list, "現れた PR の列は焦点を取らない")
  }
}
