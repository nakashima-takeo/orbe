import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// ⌥ だけの長押しの間の透かしを実窓で固定する——成立すると器が透かしになり、離すとエディターに戻ること、フォーカスと現在地が
/// エディターのままであること、前面の窓でオーバーレイが出ていない間だけ透かすこと、窓が前面でなくなったら透かしをやめること。
///
/// 壊れると何が起きるか。透かしのたびにフォーカスがエディターの本体へ当て直され、サイドバーの入力欄で打っていた字が途切れる。
/// ヘルプやパレットの後ろでエディターが消える。別のアプリへ移った後に端末が出たままになる。
extension WindowControllerFacesTests {
  /// エディターを開いた窓と、その ⌥ を操作するドライバー。前面の窓かどうかは OS とほかのアプリが決め、テストからは保てないので、
  /// 窓の条件は許すに差し替える（条件そのものは `testPeekIsAllowedOnlyInTheFrontWindowWithoutAnOverlay` が見る）。
  private func peekable() throws -> (WindowController, OptionHoldDriver) {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    let option = OptionHoldDriver(wc)
    wc.optionHold.windowAllows = { true }
    wc.toggleEditorFace()
    pumpMain(until: { !tab.group.view.isFading }, timeout: 2, "開く動きが終わる")
    return (wc, option)
  }

  private func mode(_ wc: WindowController) -> GroupFacesView.Mode? {
    wc.activeTab?.group.view.mode
  }

  /// ⌥ だけを押し続けると透かしになり、離すとエディターに戻る。フォーカスと現在地はエディターのまま。
  func testHoldingOptionPeeksAndReleasingReturnsToTheEditor() throws {
    let (wc, option) = try peekable()
    let file = TestScratch.caseDir.appendingPathComponent("a.txt")
    try Data("x".utf8).write(to: file)
    let group = try XCTUnwrap(wc.activeTab).group
    try group.openFile(file)
    let pane = group.view.editor
    wc.handleWindowCommand(.findInProject)
    pumpMain(until: { pane.focusIsInSidebar }, "前提: 本文ではなく検索パネルの入力欄にフォーカス")
    let focus = wc.window.firstResponder
    wc.refreshChrome()
    wc.flushChrome()
    let location = wc.statusModel.location

    option.hold()
    XCTAssertEqual(mode(wc), .peek)
    XCTAssertTrue(wc.window.firstResponder === focus, "フォーカスは動かない")
    wc.refreshChrome()
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.location, location, "現在地はエディターのまま")

    option.send([])
    XCTAssertEqual(mode(wc), .editor)
    XCTAssertTrue(wc.window.firstResponder === focus)
  }

  /// 透かしを許すのは、前面の窓で、オーバーレイ（ヘルプ・パレットなど）が出ていない間だけ。
  func testPeekIsAllowedOnlyInTheFrontWindowWithoutAnOverlay() throws {
    let wc = WindowController()
    wc.toggleEditorFace()
    XCTAssertFalse(wc.allowsPeek, "前面でない窓")

    makeKey(wc)
    XCTAssertTrue(wc.allowsPeek)

    wc.showHelp()
    XCTAssertFalse(wc.allowsPeek, "ヘルプの後ろ")
  }

  /// 窓が前面でなくなったら透かしをやめる。
  func testResigningKeyEndsThePeek() throws {
    let (wc, option) = try peekable()
    option.hold()
    XCTAssertEqual(mode(wc), .peek, "前提")

    wc.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))

    XCTAssertEqual(mode(wc), .editor)
  }
}
