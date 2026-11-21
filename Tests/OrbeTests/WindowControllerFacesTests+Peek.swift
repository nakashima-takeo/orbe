import AppKit
import XCTest

@testable import Orbe

/// ⌥ だけの長押しの間の透かしを実窓で固定する——成立すると器が透かしになり、離すとエディターに戻ること、フォーカスと現在地が
/// エディターのままであること、キーを打てばその場でエディターへ戻ること、オーバーレイが出ている間は透かさないこと、窓が前面で
/// なくなったら透かしをやめること。
///
/// 壊れると何が起きるか。透かしのたびにフォーカスがエディターの本体へ当て直され、サイドバーの入力欄で打っていた字が途切れる。
/// 透かしたまま打った字が見えないエディターへ入る。ヘルプやパレットの後ろでエディターが消える。別のアプリへ移った後に端末が出た
/// ままになる。
extension WindowControllerFacesTests {
  /// エディターを開いた前面の窓と、その ⌥ を操作するドライバー。
  private func peekable() throws -> (WindowController, OptionHoldDriver) {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    let option = OptionHoldDriver(wc)
    makeKey(wc)
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
    let tab = try XCTUnwrap(wc.activeTab)
    let focus = wc.window.firstResponder
    wc.flushChrome()
    let location = wc.statusModel.location

    option.hold()
    XCTAssertEqual(mode(wc), .peek)
    guard case .peek(let peeked) = wc.presentation else { return XCTFail("透かしになる") }
    XCTAssertTrue(peeked === tab)
    XCTAssertTrue(wc.window.firstResponder === focus, "フォーカスは動かない")
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.location, location, "現在地はエディターのまま")

    option.send([])
    XCTAssertEqual(mode(wc), .editor)
    XCTAssertTrue(wc.window.firstResponder === focus)
  }

  /// ⌥ を押してすぐ離せば透かさない。
  func testATapDoesNotPeek() throws {
    let (wc, option) = try peekable()
    option.send(.option)
    option.send([])
    option.pump(upTo: OptionHoldDetector.delay * 2)
    XCTAssertEqual(mode(wc), .editor)
  }

  /// 透かしたままキーを打つと、その場でエディターへ戻る（local monitor の中で同期して戻すので、キーの配送より前）。
  func testKeyDownEndsThePeekSynchronously() throws {
    let (wc, option) = try peekable()
    option.hold()
    XCTAssertEqual(mode(wc), .peek, "前提")
    let key = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
      windowNumber: wc.window.windowNumber, context: nil, characters: "π",
      charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!

    NSApp.sendEvent(key)

    XCTAssertEqual(mode(wc), .editor)
  }

  /// オーバーレイ（ヘルプ）が出ている間は透かさない。
  func testNoPeekWhileAnOverlayIsShown() throws {
    let (wc, option) = try peekable()
    wc.showHelp()
    option.send(.option)
    option.pump(upTo: OptionHoldDetector.delay * 2)
    XCTAssertEqual(mode(wc), .editor)
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
