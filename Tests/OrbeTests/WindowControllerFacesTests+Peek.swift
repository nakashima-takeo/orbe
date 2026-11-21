import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// ⌥ だけの長押しの間の透かしを実窓で固定する——成立すると器が透かしになり、離すとエディターに戻ること、フォーカスと現在地が
/// エディターのままであること、前面の窓でオーバーレイが出ていない間だけ透かすこと、窓が前面でなくなったら・エディターが閉じたら
/// 透かしをやめること。
///
/// 壊れると何が起きるか。透かしのたびにフォーカスがエディターの本体へ当て直され、サイドバーの入力欄で打っていた字が途切れる。
/// ヘルプやパレットの後ろでエディターが消える。別のアプリへ移った後に端末が出たままになる。透かしている間にタブを選んだ後、
/// ⌥ を押したまま `open_file` が届くと、フォーカスはエディターにあるのに画面には端末が出る。
extension WindowControllerFacesTests {
  /// `window` を前面の窓にしてエディターを開いた `WindowController` と、その窓の ⌥ を操作するドライバー。
  private func peekable(window: OrbeWindowFake = OrbeWindowFake()) throws -> (
    WindowController, OptionHoldDriver
  ) {
    let wc = WindowController(window: window)
    let tab = try XCTUnwrap(wc.activeTab)
    let option = OptionHoldDriver(wc)
    window.isKey = true
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
    let window = OrbeWindowFake()
    let wc = WindowController(window: window)
    wc.toggleEditorFace()
    XCTAssertFalse(wc.optionHold.windowAllows(), "前面でない窓")

    window.isKey = true
    XCTAssertTrue(wc.optionHold.windowAllows())

    wc.showHelp()
    XCTAssertFalse(wc.optionHold.windowAllows(), "ヘルプの後ろ")
  }

  /// 透かしている間にエディターが閉じたら透かしは終わり、⌥ を押したままエディターを開き直しても透かさない。
  func testClosingTheEditorWhilePeekingEndsThePeekUntilTheModifiersAreReleased() throws {
    let (wc, option) = try peekable()
    let tab = try XCTUnwrap(wc.activeTab)
    option.hold()
    XCTAssertEqual(mode(wc), .peek, "前提")

    wc.select(0)
    XCTAssertEqual(mode(wc), .terminal, "タブ行のクリックで端末")
    wc.showInEditor(tab)

    XCTAssertEqual(mode(wc), .editor, "⌥ を押したままの open_file でもエディター")
  }

  /// 窓が前面でなくなったら透かしをやめる。
  func testResigningKeyEndsThePeek() throws {
    let window = OrbeWindowFake()
    let (wc, option) = try peekable(window: window)
    option.hold()
    XCTAssertEqual(mode(wc), .peek, "前提")

    window.isKey = false

    XCTAssertEqual(mode(wc), .editor)
  }
}
